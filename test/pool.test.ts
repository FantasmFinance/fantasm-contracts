import {deployMockContract, MockContract} from '@ethereum-waffle/mock-contract';
import {BigNumber, constants, Contract, Wallet} from 'ethers';
import {expect, use} from 'chai';
import {ethers} from 'hardhat';
import {SignerWithAddress} from 'hardhat-deploy-ethers/signers';
import OracleArtifacts from '../artifacts/contracts/oracles/MasterOracle.sol/MasterOracle.json';
import FeeReserve from '../artifacts/contracts/FeeReserve.sol/FeeReserve.json';
import {parseEther, parseUnits} from 'ethers/lib/utils';

import {waffleChai} from '@ethereum-waffle/chai';
use(waffleChai);

const dec6 = (x: string) => parseUnits(x, 6);

describe.only('Pool', () => {
  let creator: Wallet;
  let alice: SignerWithAddress;

  let xftm: Contract;
  let pool: Contract;
  let fantasm: Contract;
  let devFund: Contract;
  let treasuryFund: Contract;
  let feeReserve: MockContract;
  let oracle: MockContract;
  let weth: Contract;

  before('should deploy', async () => {
    [alice] = await ethers.getUnnamedSigners();
    creator = new Wallet('0xf3ab5bb693b8b0a4982ebe004c1ed6f7c40e9d855bec996f249dedb7599a008d', ethers.provider); // test private key
    alice.sendTransaction({
      to: creator.address,
      value: parseEther('100'),
    });
    xftm = await ethers.getContractFactory('XFTM', creator).then((x) => x.deploy());
    fantasm = await ethers.getContractFactory('Fantasm', creator).then((x) => x.deploy());
    feeReserve = await deployMockContract(creator, FeeReserve.abi);
    pool = await ethers.getContractFactory('TestPool', creator).then((x) => x.deploy(xftm.address, fantasm.address, feeReserve.address));
    devFund = await ethers.getContractFactory('DevFund', creator).then((x) => x.deploy(fantasm.address));
    treasuryFund = await ethers.getContractFactory('TreasuryFund', creator).then((x) => x.deploy(fantasm.address));

    oracle = await deployMockContract(creator, OracleArtifacts.abi);
    weth = await ethers.getContractFactory('WETH').then((x) => x.deploy());
    console.log(weth.address);

    // await pool.initialize(xftm.address, fantasm.address, feeReserve.address);
    // await devFund.initialize(fantasm.address);
    // await xftm.setMinter(pool.address);
    await fantasm.transfer(alice.address, parseEther('10')); // send some genesis amount
    fantasm.connect(alice).approve(pool.address, constants.MaxUint256);
    xftm.connect(alice).approve(pool.address, constants.MaxUint256);
  });

  it('should set oracle', async () => {
    await expect(pool.connect(alice).setOracle(oracle.address)).to.reverted;
    await expect(pool.connect(creator).setOracle(constants.AddressZero)).to.reverted;
    await expect(pool.connect(creator).setOracle(oracle.address)).to.emit(pool, 'OracleChanged').withArgs(oracle.address);
    expect(await pool.oracle()).to.eq(oracle.address);
  });

  it('should return info', async () => {
    const [collateralRatio, lastRefreshCrTimestamp, mintingFee, redemptionFee, mintingPaused, redemptionPaused, collateralBalance, maxXftmSupply] = await pool.info();
    expect(collateralBalance).to.eq(0);
    expect(mintingPaused).to.be.false;
    expect(redemptionPaused).to.be.false;
    expect(collateralRatio).to.eq(dec6('1'));
  });

  it('should toggle collateral ratio', async () => {
    await expect(pool.connect(alice).toggleCollateralRatio(true)).to.reverted;
    await expect(pool.connect(creator).toggleCollateralRatio(true)).to.emit(pool, 'UpdateCollateralRatioPaused').withArgs(true);
    expect(await pool.collateralRatioPaused()).to.be.true;

    await expect(pool.connect(creator).toggleCollateralRatio(false)).to.not.reverted;
    await expect(pool.connect(creator).setMinCollateralRatio(dec6('0.8'))).to.emit(pool, 'MinCollateralRatioUpdated');
  });

  const mockFantasmPrice = async (spot: BigNumber) => {
    await oracle.mock.getFantasmPrice.returns(spot);
  };

  const refreshCr = async (target: BigNumber) => {
    await pool.setCollateralRatio(target);
  };

  // execute mint/redeem helper
  const executeTestMint = async ({
    when,
    ftmIn,
    expectedXftmOut,
    expectedFasmIn,
  }: {
    when: {
      cr: BigNumber;
    };
    ftmIn: BigNumber;
    expectedXftmOut: BigNumber;
    expectedFasmIn: BigNumber;
  }) => {
    await refreshCr(when.cr);

    const [xftmOut, minFtmIn, minFantasmIn, fee] = await pool.calcMint(ftmIn, constants.Zero);
    expect(xftmOut).to.eq(expectedXftmOut);
    expect(minFantasmIn).to.eq(expectedFasmIn);

    await expect(pool.connect(alice).mint(minFantasmIn, expectedFasmIn, {value: ftmIn}))
      .to.emit(pool, 'Mint')
      .withArgs(alice.address, xftmOut, ftmIn, minFantasmIn, fee)
      .to.not.emit(xftm, 'Transfer');

    expect(await pool.unclaimedXftm()).to.eq(xftmOut);
    const [xftmBalance, fantasmBalance, ftmBalance, lastAction] = await pool.userInfo(alice.address);
    expect(xftmBalance).to.eq(xftmOut);

    await expect(pool.connect(alice).collect()).to.emit(xftm, 'Transfer').withArgs(constants.AddressZero, alice.address, xftmOut);
  };

  const executeTestRedeem = async ({
    when,
    xftmIn,
    expectedFtmOut,
    expectedFasmOut,
  }: {
    when: {
      cr: BigNumber;
    };
    xftmIn: BigNumber;
    expectedFtmOut: BigNumber;
    expectedFasmOut: BigNumber;
  }) => {
    await refreshCr(when.cr);
    const [ftmOutput, fsmOutput, fee] = await pool.calcRedeem(xftmIn);
    expect(ftmOutput).to.eq(expectedFtmOut);
    expect(fsmOutput).to.eq(expectedFasmOut);

    await xftm.connect(alice).approve(pool.address, xftmIn);

    await expect(pool.connect(alice).redeem(xftmIn, expectedFasmOut, expectedFtmOut))
      .to.emit(pool, 'Redeem')
      .withArgs(alice.address, xftmIn, ftmOutput, fsmOutput, fee)
      .to.emit(xftm, 'Transfer')
      .withArgs(alice.address, constants.AddressZero, xftmIn);

    expect(await pool.unclaimedFtm()).to.eq(ftmOutput, 'wrong unclaimed ftm');
    expect(await pool.unclaimedFantasm()).to.eq(fsmOutput);

    const [xftmBalance, fantasmBalance, ftmBalance, lastAction] = await pool.userInfo(alice.address);

    expect(ftmBalance).to.eq(ftmOutput);
    expect(fantasmBalance).to.eq(fsmOutput);

    expect(await pool.connect(alice).collect()).to.changeEtherBalance(alice, expectedFtmOut);
  };

  describe('When CR = 100%', () => {
    before(async () => {
      await mockFantasmPrice(parseEther('0.2'));
    });

    it('should mint and claim', async () => {
      await executeTestMint({
        when: {
          cr: dec6('1'),
        },
        ftmIn: parseEther('10'),
        expectedXftmOut: parseEther('9.97'),
        expectedFasmIn: constants.Zero,
      });
    });

    it('should redeem and claim', async () => {
      await executeTestRedeem({
        when: {
          cr: dec6('1'),
        },
        xftmIn: parseEther('1'),
        expectedFtmOut: parseEther('0.995'),
        expectedFasmOut: constants.Zero,
      });
    });

    it('should calculate by fsm', async () => {
      const [xftmOut, minFtmIn, minFantasmIn, fee] = await pool.calcMint(0, parseEther('100'));
      expect(xftmOut).to.eq(0);
    });
  });

  describe('When CR < 100%', () => {
    it('should mint and claim', async () => {
      await executeTestMint({
        when: {
          cr: dec6('0.9'), // 90%
        },
        ftmIn: parseEther('9'),
        expectedXftmOut: parseEther('9.97'),
        expectedFasmIn: parseEther('5'),
      });
    });

    it('should redeem and claim', async () => {
      await executeTestRedeem({
        when: {
          cr: dec6('0.9'),
        },
        xftmIn: parseEther('1'),
        expectedFtmOut: parseEther('0.8955'),
        expectedFasmOut: parseEther('0.4975'),
      });
    });

    it('should calculate by fsm', async () => {
      await refreshCr(dec6('0.9'));
      const [xftmOut, minFtmIn, minFantasmIn, fee] = await pool.calcMint(0, parseEther('5'));
      expect(xftmOut).to.eq(parseEther('9.97'));
      expect(minFtmIn).to.eq(parseEther('9'));
      expect(minFantasmIn).to.eq(parseEther('5'));
      expect(fee).to.eq(parseEther('0.027'));
    });
  });

  describe('When CR = 0%', () => {
    it('should calculate by fsm', async () => {
      await refreshCr(dec6('0'));
      const [xftmOut, minFtmIn, minFantasmIn, fee] = await pool.calcMint(0, parseEther('50'));
      expect(xftmOut).to.eq(parseEther('9.97'));
      expect(minFtmIn).to.eq(parseEther('0'));
      expect(minFantasmIn).to.eq(parseEther('50'));
      expect(fee).to.eq(parseEther('0'));
    });
  });
});
