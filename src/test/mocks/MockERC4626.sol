// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title MockERC4626
 * @notice Simple mock ERC4626 vault for unit tests
 */
contract MockERC4626 is ERC20, IERC4626 {
    IERC20 private immutable _asset;

    constructor(address asset_, string memory name, string memory symbol) ERC20(name, symbol) {
        _asset = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1 for simplicity
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        emit Deposit(msg.sender, receiver, assets, assets);
        return assets;
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), shares);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, shares, shares);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, assets);
        }
        _burn(owner, assets);
        _asset.transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, assets);
        return assets;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        _asset.transfer(receiver, shares);
        emit Withdraw(msg.sender, receiver, owner, shares, shares);
        return shares;
    }
}
