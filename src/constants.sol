// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

uint8 constant NAV_DECIMALS = 8;

// Define the NAVCalculator contract MANAGER role ID
bytes32 constant MANAGER = keccak256("MANAGER"); // 0xaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c

// Define the OPERATOR role ID, used for bridging operations in the NAVCalculator contract
bytes32 constant OPERATOR = keccak256("OPERATOR"); // 0x523a704056dcd17bcf83bed8b68c59416dac1119be77755efe3bde0a64e46e0c

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
