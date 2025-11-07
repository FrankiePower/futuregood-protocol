// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title YieldToken
 * @author FutureGood Protocol
 * @notice ERC20 token representing the yield component of a yield-bearing asset
 * @dev YT tokens represent the right to claim yield generated
 *      Becomes worthless after market expiry. Accrued Yield can be claimed anytime using YT
 */
contract YieldToken is ERC20 {
    /// @notice Address of the contract authorized to mint and burn tokens
    /// @dev Set to YieldSplitter contract address upon deployment
    address public issuer;

    /**
     * @notice Constructs a new YieldToken with the given name and symbol
     * @dev Sets the deployer (YieldSplitter) as the issuer
     * @param _name Full name of the token (e.g., "FutureGood USDC Yield")
     * @param _symbol Token symbol (e.g., "FG-YT-USDC")
     */
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        issuer = msg.sender;
    }

    /**
     * @notice Modifier to restrict function access to the issuer only
     * @dev Prevents unauthorized minting and burning of tokens
     */
    modifier onlyIssuer() {
        require(msg.sender == issuer, "!issuer");
        _;
    }

    /**
     * @notice Mints new YT tokens to the specified address
     * @dev Only callable by the issuer (YieldSplitter contract)
     * @param to Address to receive the minted tokens
     * @param amt Amount of tokens to mint
     */
    function mint(address to, uint256 amt) external onlyIssuer {
        _mint(to, amt);
    }

    /**
     * @notice Burns YT tokens from the specified address
     * @dev Only callable by the issuer (YieldSplitter contract)
     *      Used during redemption before maturity to ensure proper token accounting
     * @param from Address to burn tokens from
     * @param amt Amount of tokens to burn
     */
    function burn(address from, uint256 amt) external onlyIssuer {
        _burn(from, amt);
    }
}
