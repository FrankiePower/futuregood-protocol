# FutureGood Protocol - Deployment Guide

## 🚀 Quick Start Deployment

### Prerequisites

1. **Foundry installed**
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. **Environment variables configured**

Create/update `.env` file:
```bash
# RPC URLs
ETH_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY

# Private key (DO NOT COMMIT)
PRIVATE_KEY=your_private_key_here

# Test Configuration (for forked tests)
TEST_ASSET_ADDRESS=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48  # USDC

# Vault Addresses (Mainnet)
AAVE_VAULT=0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6   # Aave USDC ATokenVault
MORPHO_VAULT=0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB  # Morpho USDC Vault
SPARK_VAULT=0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d   # Spark spUSDC
```

---

## 📋 Deployment Steps

### Step 1: Run Tests

Ensure everything works before deploying:

```bash
# Run all tests
forge test

# Expected: 33/33 tests passing (100%)

# Run with gas report
forge test --gas-report

# Run specific test suites
forge test --match-contract FullFlowTest -vv
```

### Step 2: Update Deployment Configuration

Edit `script/Deploy.s.sol` if needed:

```solidity
// Update these for production:
address constant POOL_MANAGER = address(0x...);  // Uniswap V4 PoolManager
address constant DRAGON_ROUTER = address(0x...); // Octant dragonRouter
```

### Step 3: Dry Run Deployment

Test deployment without broadcasting:

```bash
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL
```

### Step 4: Deploy to Mainnet

**⚠️ WARNING: This will deploy to mainnet and cost gas!**

```bash
# Deploy and broadcast transactions
forge script script/Deploy.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Alternative: Deploy with explicit private key
forge script script/Deploy.s.sol \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Step 5: Verify Contracts

If not verified during deployment:

```bash
# Verify YieldSplitter
forge verify-contract <ADDRESS> src/core/YieldSplitter.sol:YieldSplitter \
  --chain-id 1 \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Verify YieldRouter
forge verify-contract <ADDRESS> src/core/YieldRouter.sol:YieldRouter \
  --chain-id 1 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" <USDC> <AAVE> <MORPHO> <SPARK>)

# Verify each strategy similarly
```

---

## 📝 Post-Deployment Configuration

### 1. Create Yield Market

```solidity
// Call on YieldSplitter contract
yieldSplitter.createYieldMarket(
    address(USDC),           // yieldBearingToken
    address(USDC),           // assetToken
    block.timestamp + 365 days, // expiry (1 year)
    500                      // initialApr (5%)
);
```

### 2. Set YT Seller

If deploying without Uniswap V4 hook initially:

```solidity
// Set temporary YT seller (can be updated later)
yieldSplitter.setYTSeller(address(<YOUR_ADDRESS>));
```

### 3. Test Deposit

```solidity
// Approve USDC
USDC.approve(address(yieldSplitter), 100e6);

// Mint PT/YT for public goods
bytes32 marketId = keccak256(abi.encode(USDC, USDC, expiry));
yieldSplitter.mintPtAndYtForPublicGoods(marketId, 100e6);
```

### 4. Verify Deployment

```solidity
// Check YieldSplitter has shares in strategies
aaveStrategy.balanceOf(address(yieldSplitter)) // Should be > 0
morphoStrategy.balanceOf(address(yieldSplitter)) // Should be > 0
sparkStrategy.balanceOf(address(yieldSplitter)) // Should be > 0

// Check PT and YT were minted
PrincipalToken(market.principalToken).balanceOf(<USER>) // Should = deposit amount
YieldToken(market.yieldToken).balanceOf(<YTSELLER>) // Should = deposit amount
```

---

## 🔧 Advanced: Deploy with Uniswap V4 Hook

### Prerequisites

1. Uniswap V4 deployed on mainnet
2. Know the PoolManager address

### Hook Deployment (CREATE2)

The hook must be deployed at an address with correct permission flags:

```solidity
// Required flags
uint160 flags = uint160(
    Hooks.AFTER_INITIALIZE_FLAG |
    Hooks.AFTER_SWAP_FLAG
);

// Deploy using CREATE2 at address matching flags
// This requires custom deployment bytecode manipulation
```

For production deployment:

1. Use Uniswap V4's hook deployer
2. Calculate correct address with flags
3. Deploy PublicGoodsYieldHook at that address

### Create Pool with Hook

```solidity
// Create pool key
PoolKey memory key = PoolKey({
    currency0: Currency.wrap(address(YT)),
    currency1: Currency.wrap(address(USDC)),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

// Initialize pool
poolManager.initialize(key, SQRT_PRICE_1_1);

// Map pool to market in hook
hook.setPoolMarketMapping(key, marketId);
```

---

## 🏗️ Deployment Architecture

### Contracts Deployed (in order)

1. **YieldDonatingTokenizedStrategy** (implementation)
   - Octant V2 strategy base
   - Used by all 3 strategies

2. **YieldSplitter**
   - Creates PT/YT markets
   - Handles minting and redemption

3. **AaveYieldDonatingStrategy**
   - Deploys to Aave USDC vault
   - 40% of deposits

4. **MorphoYieldDonatingStrategy**
   - Deploys to Morpho USDC vault
   - 30% of deposits

5. **SparkYieldDonatingStrategy**
   - Deploys to Spark USDC vault
   - 30% of deposits

6. **YieldRouter**
   - Routes deposits 40/30/30
   - Connected to YieldSplitter

7. **PublicGoodsYieldHook** (optional, when V4 available)
   - Uniswap V4 hook
   - Auto-routes YT sale proceeds

### Contract Relationships

```
User
  ↓
YieldSplitter
  ├─> PrincipalToken (minted to user)
  ├─> YieldToken (minted to hook)
  └─> YieldRouter (deploys user's principal)
        ├─> AaveStrategy (40%)
        ├─> MorphoStrategy (30%)
        └─> SparkStrategy (30%)
              ↓
          dragonRouter (receives 100% of yield)
              ↓
          Public Goods
```

---

## 🔒 Security Considerations

### Before Mainnet Deployment

1. **Audit Recommendations**
   - ✅ YieldSplitter PT/YT logic
   - ✅ YieldRouter allocation math
   - ✅ PublicGoodsYieldHook routing logic

2. **Verified Components**
   - ✅ Octant V2 BaseStrategy (production-ready)
   - ✅ OpenZeppelin ERC20 (industry standard)
   - ✅ Uniswap V4 (when available)

3. **Testing**
   - ✅ 33/33 tests passing
   - ✅ 256-run fuzzing on critical functions
   - ✅ Fork tests against real protocols
   - ✅ Perpetual funding mechanism proven

### Production Configuration

1. **Set proper role addresses**
   - Management: Multi-sig
   - Keeper: Bot/service account
   - Emergency Admin: Multi-sig

2. **Update placeholder addresses**
   - DRAGON_ROUTER: Real Octant address
   - POOL_MANAGER: Real Uniswap V4 address

3. **Test on testnet first**
   - Deploy to Sepolia/Goerli
   - Test full flow
   - Verify contracts work as expected

---

## 📊 Deployment Costs Estimate

| Contract | Estimated Gas | Cost at 30 gwei |
|----------|--------------|-----------------|
| TokenizedStrategy | ~2M gas | ~$80 |
| YieldSplitter | ~1.5M gas | ~$60 |
| AaveStrategy | ~3M gas | ~$120 |
| MorphoStrategy | ~3M gas | ~$120 |
| SparkStrategy | ~3M gas | ~$120 |
| YieldRouter | ~1M gas | ~$40 |
| Hook (optional) | ~2M gas | ~$80 |
| **Total** | **~15.5M gas** | **~$620** |

*Estimates may vary based on network conditions*

---

## 🐛 Troubleshooting

### Issue: "USDC not set"

**Solution**: Check `.env` file has correct addresses

### Issue: "Vault not found"

**Solution**: Ensure vault addresses are correct for your network:
- Mainnet: Use addresses in `.env`
- Testnet: Deploy mock vaults or use testnet addresses

### Issue: "Hook deployment fails"

**Solution**:
- For demo: Skip hook deployment (set POOL_MANAGER = address(0))
- For production: Wait for Uniswap V4 mainnet launch
- Deploy hook using CREATE2 with correct flags

### Issue: "Out of gas"

**Solution**: Increase gas limit in forge script:
```bash
forge script script/Deploy.s.sol \
  --gas-limit 30000000 \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

---

## 📞 Support

For issues or questions:
- GitHub Issues: https://github.com/anthropics/claude-code/issues
- Documentation: See [README.md](README.md)
- Demo Guide: See [DEMO.md](DEMO.md)

---

## ✅ Deployment Checklist

- [ ] Foundry installed and up-to-date
- [ ] `.env` file configured with correct addresses
- [ ] Private key secured (not committed to git)
- [ ] All tests passing (33/33)
- [ ] Deployment script reviewed
- [ ] Dry run successful
- [ ] Sufficient ETH for gas in deployer account
- [ ] Etherscan API key configured (for verification)
- [ ] Production addresses updated (dragonRouter, etc.)
- [ ] Multi-sig addresses set for management roles
- [ ] Testnet deployment tested first
- [ ] Contracts deployed
- [ ] Contracts verified on Etherscan
- [ ] Yield market created
- [ ] Test deposit successful
- [ ] Documentation updated with deployed addresses

---

**Ready to deploy perpetual public goods funding! 🚀**
