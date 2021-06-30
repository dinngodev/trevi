// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libraries/interfaces/IERC3156.sol";
import "./FountainBase.sol";

abstract contract FountainFlashLoan is FountainBase, IERC3156FlashLender {
    /**
     * @dev The amount of currency available to be lended.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token)
        external
        view
        override
        returns (uint256)
    {
        return
            token == address(stakingToken)
                ? type(uint256).max - totalSupply()
                : 0;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        token;
        amount;
        return 0;
    }

    /**
     * @dev Initiate a flash loan.
     * @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     */
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        receiver;
        token;
        amount;
        data;
        return true;
    }
}
