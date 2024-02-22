

# Formal Verification of YieldStreaming contract  
 



## Summary

This document describes the specification and verification of YieldStreaming using the [Ethereum's hevm symbolic evaluator](https://github.com/ethereum/hevm). 

The scope of this verification is the [`YieldStreaming.sol`](https://github.com/lindy-labs/erc4626-utils/blob/main/src/YieldStreaming.sol) contract. Its specification is available [here](YieldStreaming_FV.sol).

The Ethereum's hevm symbolic evaluator proved the implementation of the YieldStreaming contract is correct with respect to formal specifications (as symbolic tests) written by the security team of Lindy Labs.  The team also performed a manual audit of these contracts.

## List of Issues Discovered

# Overview of the verification

## Description of the YieldStreaming contract

The YieldStreaming contract streamlines the administration of yield exchanges between individuals sending and receiving ERC4626 tokens. It enables users to initiate yield streams, collect yields from these streams, and terminate streams to retrieve any remaining shares. The contract operates under the assumption that ERC4626 tokens are appreciating assets, thereby indicating that the value of each share grows over time, generating yields.

## Assumptions and Simplifications

We made the following assumptions during the verification process:

- We unroll loops by max 3 times. Violations that require a loop to execute more than 3 times will not be detected;
- When verifying contracts that make external calls, we assume that those calls can have arbitrary side effects outside of the contracts, but that they do not affect the state of the contract being verified. This means that some reentrancy bugs may not be caught. However, the previous audits should have already covered all the possible reentrancy attacks;
- Concerning `openYieldStreamUsingPermit`, the use of the `permit` function of `ERC20` was simplified to provide the expected value (`owner`). This is not worrying because otherwise the operation reverted.
