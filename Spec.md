Setup
- Add tokens and create fair launch object
Pre-Launch
- Add snipe intents
Launch
- Create pool and add initial liquidity
- Execute snipe intents

*For this contract to be entirely integration agnostic it needs to:
- Not make any assumptions about the pool token
- Not make any assumptions about the quote token
- Not make any assumptions about the AMM
- Not make any assumptions about the pool token's tokenomics

For now let's assume:
- ERC20 tokens
- Uniswap V3 AMM