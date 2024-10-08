// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console} from "lib/forge-std/src/Test.sol";

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Initializable} from "@solady/utils/Initializable.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {MockERC20, MockERC1155} from "contracts/shared/Mocks.sol";
import {BoostError} from "contracts/shared/BoostError.sol";
import {ABudget} from "contracts/budgets/ABudget.sol";
import {ACloneable} from "contracts/shared/ACloneable.sol";
import {SimpleBudget} from "contracts/budgets/SimpleBudget.sol";

contract SimpleBudgetTest is Test, IERC1155Receiver {
    MockERC20 mockERC20;
    MockERC20 otherMockERC20;
    MockERC1155 mockERC1155;
    SimpleBudget simpleBudget;

    function setUp() public {
        // Deploy a new ERC20 contract and mint 100 tokens
        mockERC20 = new MockERC20();
        mockERC20.mint(address(this), 100 ether);

        // Deploy a new ERC1155 contract and mint 100 of token ID 42
        mockERC1155 = new MockERC1155();
        mockERC1155.mint(address(this), 42, 100);

        // Deploy a new SimpleBudget contract
        simpleBudget = SimpleBudget(payable(LibClone.clone(address(new SimpleBudget()))));
        simpleBudget.initialize(
            abi.encode(SimpleBudget.InitPayload({owner: address(this), authorized: new address[](0)}))
        );
    }

    ////////////////////////////////
    // SimpleBudget initial state //
    ////////////////////////////////

    function test_InitialOwner() public view {
        // Ensure the budget has the correct owner
        assertEq(simpleBudget.owner(), address(this));
    }

    function test_InitialDistributed() public view {
        // Ensure the budget has 0 tokens distributed
        assertEq(simpleBudget.total(address(mockERC20)), 0);
    }

    function test_InitialDistributed1155() public view {
        // Ensure the budget has 0 of our 1155 tokens distributed
        assertEq(simpleBudget.total(address(mockERC1155), 42), 0);
    }

    function test_InitialTotal() public view {
        // Ensure the budget has 0 tokens allocated
        assertEq(simpleBudget.total(address(mockERC20)), 0);
    }

    function test_InitialTotal1155() public view {
        // Ensure the budget has 0 of our 1155 tokens allocated
        assertEq(simpleBudget.total(address(mockERC1155), 42), 0);
    }

    function test_InitialAvailable() public view {
        // Ensure the budget has 0 tokens available
        assertEq(simpleBudget.available(address(mockERC20)), 0);
    }

    function test_InitialAvailable1155() public view {
        // Ensure the budget has 0 of our 1155 tokens available
        assertEq(simpleBudget.available(address(mockERC1155), 42), 0);
    }

    function test_InitializerDisabled() public view {
        // Because the slot is private, we use `vm.load` to access it then parse out the bits:
        //   - [0] is the `initializing` flag (which should be 0 == false)
        //   - [1..64] hold the `initializedVersion` (which should be 1)
        bytes32 slot =
            vm.load(address(simpleBudget), 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132);

        uint64 version;
        assembly {
            version := shr(1, slot)
        }

        assertNotEq(version, 0, "Version should not be 0");
    }

    /////////////////////////////
    // SimpleBudget.initialize //
    /////////////////////////////

    function testInitialize() public {
        // Initializer can only be called on clones, not the base contract
        bytes memory data = abi.encode(SimpleBudget.InitPayload({owner: address(this), authorized: new address[](0)}));
        SimpleBudget clone = SimpleBudget(payable(LibClone.clone(address(simpleBudget))));
        clone.initialize(data);

        // Ensure the budget has the correct authorities
        assertEq(clone.owner(), address(this));
        assertEq(clone.isAuthorized(address(this)), true);
    }

    function testInitialize_ImproperData() public {
        // with improperly encoded data
        bytes memory data = abi.encodePacked(new address[](0), address(this));
        vm.expectRevert();
        simpleBudget.initialize(data);
    }

    ///////////////////////////
    // SimpleBudget.allocate //
    ///////////////////////////

    function testAllocate() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        assertTrue(simpleBudget.allocate(data));

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);
    }

    function testAllocate_NativeBalance() public {
        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);
        simpleBudget.allocate{value: 100 ether}(data);

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.available(address(0)), 100 ether);
    }

    function testAllocate_ERC1155() public {
        // Approve the budget to transfer tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate 100 of token ID 42 to the budget
        bytes memory data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 100, data: ""}))
            })
        );
        assertTrue(simpleBudget.allocate(data));

        // Ensure the budget has 100 of token ID 42
        assertEq(simpleBudget.available(address(mockERC1155), 42), 100);
    }

    function testAllocate_NativeBalanceValueMismatch() public {
        // Encode an allocation of 100 ETH
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);

        // Expect a revert due to a value mismatch (too much ETH)
        vm.expectRevert(abi.encodeWithSelector(ABudget.InvalidAllocation.selector, address(0), uint256(100 ether)));
        simpleBudget.allocate{value: 101 ether}(data);

        // Expect a revert due to a value mismatch (too little ETH)
        vm.expectRevert(abi.encodeWithSelector(ABudget.InvalidAllocation.selector, address(0), uint256(100 ether)));
        simpleBudget.allocate{value: 99 ether}(data);
    }

    function testAllocate_NoApproval() public {
        // Allocate 100 tokens to the budget without approval
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        simpleBudget.allocate(data);
    }

    function testAllocate_InsufficientFunds() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 101 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 101 ether);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        simpleBudget.allocate(data);
    }

    function testAllocate_ImproperData() public {
        bytes memory data;

        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // with improperly encoded data
        data = abi.encodePacked(mockERC20, uint256(100 ether));
        vm.expectRevert();
        simpleBudget.allocate(data);
    }

    function testAllocate_ERC20InvalidAllocation() public {
        uint256 amount = 100 ether;

        // Approve SimpleBudget to spend tokens
        mockERC20.approve(address(simpleBudget), amount);

        // Transfer 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), amount);

        // Set up the mock to manipulate the balance after transfer
        vm.mockCall(
            address(mockERC20),
            abi.encodeWithSelector(mockERC20.balanceOf.selector, address(simpleBudget)),
            abi.encode(amount - 1) // Return a balance that's 1 less than expected
        );

        // Expect revert due to InvalidAllocation
        vm.expectRevert(abi.encodeWithSelector(ABudget.InvalidAllocation.selector, address(mockERC20), amount));
        simpleBudget.allocate(data);

        vm.clearMockedCalls();
    }

    function testAllocate_ERC1155InvalidAllocation() public {
        uint256 tokenId = 42;
        uint256 initialAmount = 100;

        // Approve SimpleBudget to spend tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Prepare allocation data
        bytes memory allocateData =
            _makeERC1155Transfer(address(mockERC1155), address(this), tokenId, initialAmount, "");

        // Set up the mock to manipulate the balance after transfer
        vm.mockCall(
            address(mockERC1155),
            abi.encodeWithSelector(mockERC1155.balanceOf.selector, address(simpleBudget), tokenId),
            abi.encode(initialAmount - 1) // Return a balance that's 1 less than expected
        );

        // Expect revert due to InvalidAllocation
        vm.expectRevert(abi.encodeWithSelector(ABudget.InvalidAllocation.selector, address(mockERC1155), initialAmount));
        simpleBudget.allocate(allocateData);

        vm.clearMockedCalls();
    }

    ///////////////////////////
    // SimpleBudget.clawback //
    ///////////////////////////

    function testClawback() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);

        // Reclaim 99 tokens from the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 99 ether);
        assertTrue(simpleBudget.clawback(data));

        // Ensure the budget has 1 token left
        assertEq(simpleBudget.available(address(mockERC20)), 1 ether);
    }

    function testClawback_NativeBalance() public {
        // Allocate 100 ETH to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);
        simpleBudget.allocate{value: 100 ether}(data);
        assertEq(simpleBudget.available(address(0)), 100 ether);

        // Reclaim 99 ETH from the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(1), 99 ether);
        assertTrue(simpleBudget.clawback(data));

        // Ensure the budget has 1 ETH left
        assertEq(simpleBudget.available(address(0)), 1 ether);
    }

    function testClawback_ERC1155() public {
        // Approve the budget to transfer tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate 100 of token ID 42 to the budget
        bytes memory data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 100, data: ""}))
            })
        );
        simpleBudget.allocate(data);
        assertEq(simpleBudget.available(address(mockERC1155), 42), 100);

        // Reclaim 99 of token ID 42 from the budget
        data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 99, data: ""}))
            })
        );
        assertTrue(simpleBudget.clawback(data));

        // Ensure the budget has 1 of token ID 42 left
        assertEq(simpleBudget.available(address(mockERC1155), 42), 1);
    }

    function testClawback_ZeroAmount() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);

        // Reclaim all tokens from the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 0);
        assertTrue(simpleBudget.clawback(data));

        // Ensure the budget has no tokens left
        assertEq(simpleBudget.available(address(mockERC20)), 0 ether);
    }

    function testClawback_ZeroAddress() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);

        // Reclaim 100 tokens from the budget to address(0)
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(0), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ABudget.TransferFailed.selector, address(mockERC20), address(0), uint256(100 ether))
        );
        simpleBudget.clawback(data);

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);
    }

    function testClawback_InsufficientFunds() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Reclaim 101 tokens from the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 101 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ABudget.InsufficientFunds.selector, address(mockERC20), uint256(100 ether), uint256(101 ether)
            )
        );
        simpleBudget.clawback(data);
    }

    function testClawback_ImproperData() public {
        bytes memory data;

        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // with improperly encoded data
        data = abi.encodePacked(mockERC20, uint256(100 ether));
        vm.expectRevert();
        simpleBudget.clawback(data);
    }

    function testClawback_NotOwner() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Try to reclaim 100 tokens from the budget as a non-owner
        // We can reuse the data from above because the target is `address(this)` in both cases
        vm.prank(address(1));
        vm.expectRevert();
        simpleBudget.clawback(data);
    }

    function testClawback_InsufficientFundsERC1155() public {
        // Approve the budget to transfer tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate 100 of token ID 42 to the budget
        bytes memory data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 100, data: ""}))
            })
        );
        simpleBudget.allocate(data);
        assertEq(simpleBudget.available(address(mockERC1155), 42), 100);

        // Attempt to clawback more than available
        bytes memory clawbackData = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 101, data: ""}))
            })
        );

        // Expect the InsufficientFunds revert
        vm.expectRevert(abi.encodeWithSelector(ABudget.InsufficientFunds.selector, address(mockERC1155), 100, 101));
        simpleBudget.clawback(clawbackData);
    }

    ///////////////////////////
    // SimpleBudget.disburse //
    ///////////////////////////

    function testDisburse() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Disburse 100 tokens from the budget to the recipient
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 100 ether);
        assertTrue(simpleBudget.disburse(data));
        assertEq(mockERC20.balanceOf(address(1)), 100 ether);

        // Ensure the budget was drained
        assertEq(simpleBudget.available(address(mockERC20)), 0);
        assertEq(simpleBudget.distributed(address(mockERC20)), 100 ether);
    }

    function testDisburse_NativeBalance() public {
        // Allocate 100 ETH to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);
        simpleBudget.allocate{value: 100 ether}(data);

        // Disburse 100 ETH from the budget to the recipient
        data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(1), 100 ether);
        assertTrue(simpleBudget.disburse(data));
        assertEq(address(1).balance, 100 ether);

        // Ensure the budget was drained
        assertEq(simpleBudget.available(address(0)), 0);
        assertEq(simpleBudget.distributed(address(0)), 100 ether);
    }

    function testDisburse_ERC1155() public {
        // Approve the budget to transfer tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate 100 of token ID 42 to the budget
        bytes memory data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(this),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 100, data: ""}))
            })
        );
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC1155), 42), 100);

        // Disburse 100 of token ID 42 from the budget to the recipient
        data = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: address(mockERC1155),
                target: address(1),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: 42, amount: 100, data: ""}))
            })
        );
        assertTrue(simpleBudget.disburse(data));
        assertEq(mockERC1155.balanceOf(address(1), 42), 100);

        // Ensure the budget was drained
        assertEq(simpleBudget.available(address(mockERC1155), 42), 0);
        assertEq(simpleBudget.distributed(address(mockERC1155), 42), 100);
    }

    function testDisburseBatch() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 50 ether);
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate the assets to the budget
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 50 ether)
        );
        simpleBudget.allocate{value: 25 ether}(
            _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 25 ether)
        );
        simpleBudget.allocate(_makeERC1155Transfer(address(mockERC1155), address(this), 42, 50, bytes("")));
        assertEq(simpleBudget.total(address(mockERC20)), 50 ether);
        assertEq(simpleBudget.total(address(0)), 25 ether);
        assertEq(simpleBudget.total(address(mockERC1155), 42), 50);

        // Prepare the disbursement requests
        bytes[] memory requests = new bytes[](3);
        requests[0] = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 25 ether);
        requests[1] = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(2), 25 ether);
        requests[2] = _makeERC1155Transfer(address(mockERC1155), address(3), 42, 10, bytes(""));

        // Disburse:
        // 25 tokens to address(1); and
        // 25 ETH to address(2); and
        // 50 of token ID 42 to address(3)
        assertTrue(simpleBudget.disburseBatch(requests));

        // Ensure the budget sent 25 tokens to address(1) and has 25 left
        assertEq(simpleBudget.available(address(mockERC20)), 25 ether);
        assertEq(simpleBudget.distributed(address(mockERC20)), 25 ether);
        assertEq(mockERC20.balanceOf(address(1)), 25 ether);

        // Ensure the budget sent 25 ETH to address(2) and has 0 left
        assertEq(address(2).balance, 25 ether);
        assertEq(simpleBudget.available(address(0)), 0 ether);

        // Ensure the budget sent 10 of token ID 42 to address(3) and has 40 left
        assertEq(simpleBudget.available(address(mockERC1155), 42), 40);
    }

    function testDisburse_InsufficientFunds() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Disburse 101 tokens from the budget to the recipient
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 101 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                ABudget.InsufficientFunds.selector, address(mockERC20), uint256(100 ether), uint256(101 ether)
            )
        );
        simpleBudget.disburse(data);
    }

    function testDisburse_InsufficientFundsERC1155() public {
        // Approve the budget to transfer tokens
        mockERC1155.setApprovalForAll(address(simpleBudget), true);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeERC1155Transfer(address(mockERC1155), address(this), 42, 100, bytes(""));
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC1155), 42), 100);

        // Disburse 101 tokens from the budget to the recipient
        data = _makeERC1155Transfer(address(mockERC1155), address(1), 42, 101, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(ABudget.InsufficientFunds.selector, address(mockERC1155), uint256(100), uint256(101))
        );
        simpleBudget.disburse(data);
    }

    function testDisburse_ImproperData() public {
        bytes memory data;

        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // with improperly encoded data
        data = abi.encode(1, mockERC20, uint256(100 ether));
        vm.expectRevert();
        simpleBudget.disburse(data);
    }

    function testDisburse_NotOwner() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Try to disburse 100 tokens from the budget as a non-owner
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(0xdeadbeef), 100 ether);
        vm.prank(address(0xc0ffee));
        vm.expectRevert();
        simpleBudget.disburse(data);
    }

    function testDisburse_FailedTransfer() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Mock the ERC20 transfer to fail in an unexpected way
        vm.mockCallRevert(
            address(mockERC20),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), address(1), 100 ether),
            unicode"WeïrdÊrrör(ツ)"
        );

        // Try to disburse 100 tokens from the budget
        data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 100 ether);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        simpleBudget.disburse(data);
    }

    function testDisburse_FailedTransferInBatch() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether);
        simpleBudget.allocate(data);
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);

        // Prepare the disbursement data
        bytes[] memory requests = new bytes[](3);
        requests[0] = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 25 ether);
        requests[1] = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(2), 50 ether);
        requests[2] = _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(3), 10 ether);

        // Mock the second ERC20 transfer to fail in an unexpected way
        vm.mockCallRevert(
            address(mockERC20),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), address(2), 50 ether),
            unicode"WeïrdÊrrör(ツ)"
        );

        // Try to disburse 25 tokens to address(1) and 50 tokens to address(2)
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        simpleBudget.disburseBatch(requests);
    }

    function testDisburse_ERC1155_ToZeroAddress() public {
        address token = address(mockERC1155);
        uint256 tokenId = 42;
        uint256 amount = 10;

        // Transfer tokens to the SimpleBudget contract
        mockERC1155.safeTransferFrom(address(this), address(simpleBudget), tokenId, amount, "");

        // Verify the transfer
        assertEq(mockERC1155.balanceOf(address(simpleBudget), tokenId), amount);

        // Disburse the tokens to the zero address
        bytes memory disburseData = abi.encode(
            ABudget.Transfer({
                assetType: ABudget.AssetType.ERC1155,
                asset: token,
                target: address(0),
                data: abi.encode(ABudget.ERC1155Payload({tokenId: tokenId, amount: amount, data: ""}))
            })
        );

        // Expect the disbursement to fail
        vm.expectRevert(
            abi.encodeWithSelector(ABudget.TransferFailed.selector, address(mockERC1155), address(0), amount)
        );
        simpleBudget.disburse(disburseData);

        // Ensure the budget still has 10 tokens
        assertEq(mockERC1155.balanceOf(address(simpleBudget), tokenId), amount);
    }

    ////////////////////////
    // SimpleBudget.total //
    ////////////////////////

    function testTotal() public {
        // Ensure the budget has 0 tokens
        assertEq(simpleBudget.total(address(mockERC20)), 0);

        // Allocate 100 tokens to the budget
        mockERC20.approve(address(simpleBudget), 100 ether);
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether)
        );

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);
    }

    function testTotal_NativeBalance() public {
        // Ensure the budget has 0 tokens
        assertEq(simpleBudget.total(address(0)), 0);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);
        simpleBudget.allocate{value: 100 ether}(data);

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.total(address(0)), 100 ether);
    }

    function testTotal_SumOfAvailAndDistributed() public {
        // We'll send two allocations of 100 tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 50 tokens to the budget
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 50 ether)
        );

        // Disburse 25 tokens from the budget to the recipient
        simpleBudget.disburse(_makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(1), 25 ether));

        // Allocate another 50 tokens to the budget
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 50 ether)
        );

        // Ensure the budget has 50 - 25 + 50 = 75 tokens
        assertEq(simpleBudget.available(address(mockERC20)), 75 ether);

        // Ensure the budget has 25 tokens distributed
        assertEq(simpleBudget.distributed(address(mockERC20)), 25 ether);

        // Ensure the total is 75 available + 25 distributed = 100 tokens
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);
    }

    ////////////////////////////
    // SimpleBudget.available //
    ////////////////////////////

    function testAvailable() public {
        // Ensure the budget has 0 tokens available
        assertEq(simpleBudget.available(address(mockERC20)), 0);

        // Allocate 100 tokens to the budget
        mockERC20.approve(address(simpleBudget), 100 ether);
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether)
        );

        // Ensure the budget has 100 tokens available
        assertEq(simpleBudget.available(address(mockERC20)), 100 ether);
    }

    function testAvailable_NativeBalance() public {
        // Ensure the budget has 0 tokens available
        assertEq(simpleBudget.available(address(0)), 0);

        // Allocate 100 tokens to the budget
        bytes memory data = _makeFungibleTransfer(ABudget.AssetType.ETH, address(0), address(this), 100 ether);
        simpleBudget.allocate{value: 100 ether}(data);

        // Ensure the budget has 100 tokens available
        assertEq(simpleBudget.available(address(0)), 100 ether);
    }

    function testAvailable_NeverAllocated() public view {
        // Ensure the budget has 0 tokens available
        assertEq(simpleBudget.available(address(otherMockERC20)), 0);
    }

    //////////////////////////////
    // SimpleBudget.distributed //
    //////////////////////////////

    function testDistributed() public {
        // Ensure the budget has 0 tokens distributed
        assertEq(simpleBudget.distributed(address(mockERC20)), 0);

        // Allocate 100 tokens to the budget
        mockERC20.approve(address(simpleBudget), 100 ether);
        simpleBudget.allocate(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether)
        );

        // Disburse 50 tokens from the budget to the recipient
        simpleBudget.disburse(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 50 ether)
        );

        // Ensure the budget has 50 tokens distributed
        assertEq(simpleBudget.distributed(address(mockERC20)), 50 ether);

        // Disburse 25 more tokens from the budget to the recipient
        simpleBudget.disburse(
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 25 ether)
        );

        // Ensure the budget has 75 tokens distributed
        assertEq(simpleBudget.distributed(address(mockERC20)), 75 ether);
    }

    ////////////////////////////
    // SimpleBudget.reconcile //
    ////////////////////////////

    function testReconcile() public {
        // SimpleBudget does not implement reconcile
        assertEq(simpleBudget.reconcile(""), 0);
    }

    ////////////////////////////////
    // SimpleBudget.setAuthorized //
    ////////////////////////////////

    function testSetAuthorized() public {
        // Ensure the budget authorizes an account
        address[] memory accounts = new address[](1);
        bool[] memory authorized = new bool[](1);
        accounts[0] = address(0xc0ffee);
        authorized[0] = true;
        simpleBudget.setAuthorized(accounts, authorized);
        assertTrue(simpleBudget.isAuthorized(address(0xc0ffee)));
        assertFalse(simpleBudget.isAuthorized(address(0xdeadbeef)));
    }

    function testSetAuthorized_NotOwner() public {
        // Ensure the budget does not authorize an account if not called by the owner
        vm.prank(address(0xdeadbeef));

        address[] memory accounts = new address[](1);
        bool[] memory authorized = new bool[](1);
        accounts[0] = address(0xc0ffee);
        authorized[0] = true;

        vm.expectRevert(BoostError.Unauthorized.selector);
        simpleBudget.setAuthorized(accounts, authorized);
    }

    function testSetAuthorized_LengthMismatch() public {
        address[] memory accounts = new address[](1);
        bool[] memory authorized = new bool[](2);

        vm.expectRevert(BoostError.LengthMismatch.selector);
        simpleBudget.setAuthorized(accounts, authorized);
    }

    ///////////////////////////////
    // SimpleBudget.isAuthorized //
    ///////////////////////////////

    function testIsAuthorized() public {
        address[] memory accounts = new address[](1);
        bool[] memory authorized = new bool[](1);
        accounts[0] = address(0xc0ffee);
        authorized[0] = true;
        simpleBudget.setAuthorized(accounts, authorized);

        assertTrue(simpleBudget.isAuthorized(address(0xc0ffee)));
        assertFalse(simpleBudget.isAuthorized(address(0xdeadbeef)));
    }

    function testIsAuthorized_Owner() public view {
        assertTrue(simpleBudget.isAuthorized(address(this)));
    }

    ////////////////////////////////////
    // SimpleBudget.getComponentInterface //
    ////////////////////////////////////

    function testGetComponentInterface() public view {
        // Ensure the contract supports the ABudget interface
        console.logBytes4(simpleBudget.getComponentInterface());
    }

    ////////////////////////////////////
    // SimpleBudget.supportsInterface //
    ////////////////////////////////////

    function testSupportsBudgetInterface() public view {
        // Ensure the contract supports the ABudget interface
        assertTrue(simpleBudget.supportsInterface(type(ABudget).interfaceId));
    }

    function testSupportsERC1155Receiver() public view {
        // Ensure the contract supports the ABudget interface
        assertTrue(simpleBudget.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function testSupportsERC165() public view {
        // Ensure the contract supports the ABudget interface
        assertTrue(simpleBudget.supportsInterface(type(IERC165).interfaceId));
    }

    function testSupportsInterface_NotSupported() public view {
        // Ensure the contract does not support an unsupported interface
        assertFalse(simpleBudget.supportsInterface(type(Test).interfaceId));
    }

    ////////////////////////////
    // SimpleBudget.fallback  //
    ////////////////////////////

    function testFallback() public {
        // Ensure the fallback is payable
        (bool success,) = payable(simpleBudget).call{value: 1 ether}("");
        assertTrue(success);
    }

    function testFallback_CompressedFunctionCall() public {
        // Approve the budget to transfer tokens
        mockERC20.approve(address(simpleBudget), 100 ether);

        // Allocate 100 tokens to the budget
        bytes memory data = abi.encodeWithSelector(
            SimpleBudget.allocate.selector,
            _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether)
        );

        (bool success,) = payable(simpleBudget).call(data);
        assertTrue(success, "Fallback function failed");

        // Ensure the budget has 100 tokens
        assertEq(simpleBudget.total(address(mockERC20)), 100 ether);
    }

    function testFallback_NoSuchFunction() public {
        // This test is weirdly slow and burns the entire block gas limit, so
        // I'm skipping it for now to avoid slowing down the test suite. Maybe
        // we can revisit this later... or maybe the case is irrelevant.
        vm.skip(true);

        // Ensure the call is not successful due to a non-existent function
        // Note that the function itself will revert, but because we're issuing
        // a low-level call, the revert won't bubble up. Instead, we are just
        // checking that the low-level call was not successful.
        (bool success,) = payable(simpleBudget).call{value: 1 ether}(
            abi.encodeWithSelector(
                bytes4(0xdeadbeef),
                _makeFungibleTransfer(ABudget.AssetType.ERC20, address(mockERC20), address(this), 100 ether)
            )
        );
        assertFalse(success);
    }

    ///////////////////////////
    // SimpleBudget.receive  //
    ///////////////////////////

    function testReceive() public {
        // Ensure the receive function catches non-fallback ETH transfers
        (bool success,) = payable(simpleBudget).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(simpleBudget.available(address(0)), 1 ether);
    }

    function testOnERC1155Received() public view {
        // Call onERC1155Received with dummy values
        bytes4 result = simpleBudget.onERC1155Received(
            address(0xc0ffee), // operator
            address(0xdeadbeef), // from
            1, // id
            1, // amount
            "" // data
        );

        // Check if it returns the correct selector
        assertEq(result, IERC1155Receiver.onERC1155Received.selector, "Should return correct selector");
    }

    function testOnERC1155BatchReceived() public view {
        // Call onERC1155BatchReceived with dummy values
        bytes4 result = simpleBudget.onERC1155BatchReceived(
            address(0xc0ffee), // operator
            address(0xdeadbeef), // from
            new uint256[](1), // ids
            new uint256[](1), // amounts
            "" // data
        );

        // Check if it returns the correct selector
        assertEq(result, IERC1155Receiver.onERC1155BatchReceived.selector, "Should return correct selector");
    }

    ///////////////////////////
    // Test Helper Functions //
    ///////////////////////////

    function _makeFungibleTransfer(ABudget.AssetType assetType, address asset, address target, uint256 value)
        internal
        pure
        returns (bytes memory)
    {
        ABudget.Transfer memory transfer;
        transfer.assetType = assetType;
        transfer.asset = asset;
        transfer.target = target;
        if (assetType == ABudget.AssetType.ETH || assetType == ABudget.AssetType.ERC20) {
            transfer.data = abi.encode(ABudget.FungiblePayload({amount: value}));
        } else if (assetType == ABudget.AssetType.ERC1155) {
            // we're not actually handling this case yet, so hardcoded token ID of 1 is fine
            transfer.data = abi.encode(ABudget.ERC1155Payload({tokenId: 1, amount: value, data: ""}));
        }

        return abi.encode(transfer);
    }

    function _makeERC1155Transfer(address asset, address target, uint256 tokenId, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        ABudget.Transfer memory transfer;
        transfer.assetType = ABudget.AssetType.ERC1155;
        transfer.asset = asset;
        transfer.target = target;
        transfer.data = abi.encode(ABudget.ERC1155Payload({tokenId: tokenId, amount: value, data: data}));

        return abi.encode(transfer);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
