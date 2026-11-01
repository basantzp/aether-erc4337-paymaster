// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount, PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockAccount is IAccount {
    address public owner;
    address public immutable entryPoint;

    event Executed(address indexed target, uint256 value, bytes data);

    constructor(address _owner, address _entryPoint) {
        owner = _owner;
        entryPoint = _entryPoint;
    }

    modifier onlyEntryPoint() {
        require(msg.sender == entryPoint, "MockAccount: not EntryPoint");
        _;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        onlyEntryPoint
        returns (uint256 validationData)
    {
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            require(success, "MockAccount: failed to pay missing funds");
        }

        // Validate account signature
        if (userOp.signature.length == 65) {
            bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
            address signer = ECDSA.recover(ethHash, userOp.signature);
            if (signer != owner) {
                return 1; // SIG_VALIDATION_FAILED
            }
        }
        return 0; // Success
    }

    function execute(address dest, uint256 value, bytes calldata func) external onlyEntryPoint {
        (bool success, bytes memory result) = dest.call{value: value}(func);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        emit Executed(dest, value, func);
    }

    receive() external payable {}
}
