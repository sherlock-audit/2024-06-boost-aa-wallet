// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ACloneable} from "contracts/shared/ACloneable.sol";

/// @title Boost AllowList
/// @notice Abstract contract for a generic Allow List within the Boost protocol
/// @dev Allow List classes are expected to implement the authorization of users based on implementation-specific criteria, which may involve validation of a data payload. If no data is required, calldata should be empty.
abstract contract AAllowList is ACloneable {
    /// @notice Check if a user is authorized
    /// @param user_ The address of the user
    /// @param data_ The data payload for the authorization check, if applicable
    /// @return True if the user is authorized
    function isAllowed(address user_, bytes calldata data_) external view virtual returns (bool);

    /// @inheritdoc ACloneable
    function supportsInterface(bytes4 interfaceId) public view virtual override(ACloneable) returns (bool) {
        return interfaceId == type(AAllowList).interfaceId || super.supportsInterface(interfaceId);
    }
}
