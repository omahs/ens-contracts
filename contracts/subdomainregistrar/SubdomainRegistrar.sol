//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../wrapper/INameWrapper.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "hardhat/console.sol";

error Unavailable();
error Unauthorised(bytes32 node);
error InsufficientFunds();
error NameNotRegistered();

struct Name {
    uint256 registrationFee;
    address beneficiary;
}

contract SubdomainRegistrar is ERC1155Holder {
    INameWrapper public immutable wrapper;
    using Address for address;

    mapping(bytes32 => Name) public names;
    mapping(bytes32 => uint256) public expiries;

    event NameRenewed(bytes32 node, uint256 duration);

    constructor(INameWrapper _wrapper) {
        wrapper = _wrapper;
    }

    modifier onlyOwner(bytes32 node) {
        if (!wrapper.isTokenOwnerOrApproved(node, msg.sender)) {
            revert Unauthorised(node);
        }
        _;
    }

    function setupDomain(
        bytes32 node,
        uint256 fee,
        address beneficiary
    ) public onlyOwner(node) {
        setRegistrationFee(node, fee);
        names[node].beneficiary = beneficiary;
    }

    function setRegistrationFee(bytes32 node, uint256 fee)
        public
        onlyOwner(node)
    {
        names[node].registrationFee = fee;
    }

    function available(bytes32 node) public returns (bool) {
        (, uint64 expiry) = wrapper.getFuses(node);
        return expiry < block.timestamp;
    }

    function register(
        bytes32 parentNode,
        string calldata label,
        address newOwner,
        address resolver,
        uint32 fuses,
        uint64 duration,
        bytes[] calldata records
    ) public payable {
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(parentNode, labelhash));
        uint256 registrationFee = duration * names[parentNode].registrationFee;

        if (!available(node)) {
            revert Unavailable();
        }
        if (msg.value < registrationFee) {
            revert InsufficientFunds();
        }

        if (records.length > 0) {
            wrapper.setSubnodeOwner(
                parentNode,
                label,
                address(this),
                0,
                uint64(block.timestamp + duration)
            );
            _setRecords(node, resolver, records);
        }

        wrapper.setSubnodeRecord(
            parentNode,
            label,
            newOwner,
            resolver,
            0,
            fuses | PARENT_CANNOT_CONTROL, // burn the ability for the parent to control
            uint64(block.timestamp + duration)
        );

        names[parentNode].beneficiary.call{value: registrationFee}("");
    }

    function renew(
        bytes32 parentNode,
        bytes32 labelhash,
        uint64 duration
    ) external payable returns (uint64 newExpiry) {
        bytes32 node = _makeNode(parentNode, labelhash);
        (, uint64 expiry) = wrapper.getFuses(node);
        if (expiry < block.timestamp) {
            revert NameNotRegistered();
        }

        uint256 renewalFee = duration * names[parentNode].registrationFee;

        newExpiry = expiry += duration;

        wrapper.setChildFuses(parentNode, labelhash, 0, newExpiry);

        (bool sent, ) = names[parentNode].beneficiary.call{value: renewalFee}(
            ""
        );

        if (!sent) {
            revert();
        }

        emit NameRenewed(node, newExpiry);
    }

    function _setRecords(
        bytes32 node,
        address resolver,
        bytes[] calldata records
    ) internal {
        for (uint256 i = 0; i < records.length; i++) {
            // check first few bytes are namehash
            bytes32 txNamehash = bytes32(records[i][4:36]);
            require(
                txNamehash == node,
                "SubdomainRegistrar: Namehash on record do not match the name being registered"
            );
            resolver.functionCall(
                records[i],
                "SubdomainRegistrar: Failed to set Record"
            );
        }
    }

    function _makeNode(bytes32 node, bytes32 labelhash)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(node, labelhash));
    }
}
