// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIsCalled = 0;
    address[] public usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        dsc = _dsc;
        engine = _engine;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, collateralBalance);
        if (amountCollateral == 0) return;

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDSC(uint256 amountDSCToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) return;
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        vm.startPrank(sender);

        (uint256 amountDSCAlreadyMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);

        uint256 maxDSCToMint = (collateralValueInUsd / 2) - amountDSCAlreadyMinted;
        if (maxDSCToMint < 0) return;

        amountDSCToMint = bound(amountDSCToMint, 0, uint256(maxDSCToMint));
        if (amountDSCToMint == 0) return;

        engine.mintDsc(amountDSCToMint);
        timeMintIsCalled++;
        vm.stopPrank();
    }

    // Helper Fucntion
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return weth;
        return wbtc;
    }
}
