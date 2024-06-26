// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator ethUsdPriceFeed;
    MockV3Aggregator btcUsdPriceFeed;

    address[] public usersWhoMintedDSC;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public mintAndDepositCollateralNumberOfCall = 0;
    uint256 public redeemCollateralNumberOfCall = 0;
    uint256 public mintDSCNumberOfCall = 0;
    uint256 public burnDSCNumberOfCall = 0;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralPriceFeed(address(wbtc)));
    }

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        mintAndDepositCollateralNumberOfCall++;

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        redeemCollateralNumberOfCall++;

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) return;

        (uint256 amountDSCMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        uint256 valueOfCollateralToRedeemInUsd = engine.getUsdValue(address(collateral), amountCollateral);
        if (
            engine.calculateHealthFactor(amountDSCMinted, collateralValueInUsd - valueOfCollateralToRedeemInUsd)
                < engine.getMinHealthFactor()
        ) return;

        vm.startPrank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDSC(uint256 amountDSCToMint) public {
        mintDSCNumberOfCall++;

        (uint256 amountDSCAlreadyMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        uint256 maxDSCToMint = (collateralValueInUsd / 2) - amountDSCAlreadyMinted;

        if (maxDSCToMint < 0) return;

        amountDSCToMint = bound(amountDSCToMint, 0, maxDSCToMint);
        if (amountDSCToMint == 0) return;

        vm.startPrank(msg.sender);

        engine.mintDsc(amountDSCToMint);
        usersWhoMintedDSC.push(msg.sender);
        vm.stopPrank();
    }

    function burnDsc(uint256 amountToBurn, uint256 seedIndexUserWhoMinted) public {
        burnDSCNumberOfCall++;

        if (usersWhoMintedDSC.length == 0) return;
        address user = usersWhoMintedDSC[seedIndexUserWhoMinted % usersWhoMintedDSC.length];

        amountToBurn = bound(amountToBurn, 0, engine.getTotalMinted(user));
        if (amountToBurn == 0) return;

        vm.startPrank(user);
        dsc.approve(address(engine), amountToBurn);
        engine.burnDSC(amountToBurn);
        vm.stopPrank();
    }

    function liquidate(address userToLiquidate, uint256 collateralSeed, uint256 debtToCover) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        ERC20Mock collateral2 = _getCollateralFromSeed(collateralSeed + 1);

        uint256 minimumHealthFactor = engine.getMinHealthFactor();
        uint256 userHealthFactor = engine.getHealthFactor(userToLiquidate);

        if (userHealthFactor >= minimumHealthFactor) return;
        if (engine.getCollateralBalanceOfUser(userToLiquidate, address(collateral)) == 0) return;

        uint256 userBalanceOfDSC = engine.getTotalMinted(userToLiquidate);
        if (userBalanceOfDSC == 0) return;
        debtToCover = bound(debtToCover, 1, userBalanceOfDSC);

        uint256 amountCollateral = engine.getTokenAmountFromUsd(address(collateral2), debtToCover * 2e8);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        mintDSC(debtToCover);

        vm.startPrank(msg.sender);
        dsc.approve(msg.sender, debtToCover);
        dsc.approve(address(engine), debtToCover);
        engine.liquidate(address(collateral), userToLiquidate, debtToCover);
        vm.stopPrank();
    }

    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        MockV3Aggregator priceFeed = MockV3Aggregator(engine.getCollateralPriceFeed(address(collateral)));
        priceFeed.updateAnswer(newPriceInt);

        for (uint256 i = 0; i < usersWhoMintedDSC.length; i++) {
            liquidate(usersWhoMintedDSC[i], collateralSeed, dsc.balanceOf(usersWhoMintedDSC[i]));
        }
    }

    // Helper Function
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return weth;
        return wbtc;
    }

    function getUserWhoMintedDSCLength() external view returns (uint256) {
        return usersWhoMintedDSC.length;
    }
}
