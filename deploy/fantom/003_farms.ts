import {constants} from 'ethers';
import {DeployFunction} from 'hardhat-deploy/dist/types';

const Addresses = {
  lp_xftm_eth: '0x128aff18EfF64dA69412ea8d262DC4ef8bb3102d',
  lp_fsm_eth: '0x457C8Efcd523058dd58CF080533B41026788eCee',
};
const func: DeployFunction = async ({deployments, getNamedAccounts}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();
  const farm = await deploy('FantasmChef', {
    from: deployer,
    log: true,
  });

  const fsm = await get('Fantasm');
  const pool = await get('Pool');
  const wethUtils = await get('WethUtils');

  const feeDistributor = await deploy('MultiFeeDistribution', {
    from: deployer,
    log: true,
    args: [fsm.address, [farm.address]],
    libraries: {
      WethUtils: wethUtils.address,
    },
  });

  await execute(
    'FantasmChef',
    {from: deployer, log: true},
    'setRewardMinter',
    feeDistributor.address
  );

  await execute(
    'FantasmChef',
    {from: deployer, log: true},
    'add',
    30000,
    Addresses.lp_fsm_eth,
    constants.AddressZero
  );

  await execute(
    'FantasmChef',
    {from: deployer, log: true},
    'add',
    70000,
    Addresses.lp_xftm_eth,
    constants.AddressZero
  );

  const feeReserve = await deploy('FeeReserve', {
    from: deployer,
    log: true,
    args: [feeDistributor.address, pool.address],
  });

  const wftm = '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83';
  await execute(
    'MultiFeeDistribution',
    {from: deployer, log: true},
    'addReward',
    wftm,
    feeReserve.address
  );

  const swapRouter = '0xF491e7B69E4244ad4002BC14e878a34207E38c29';
  const swapSlippage = 20000; // 2%
  const weth = '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83';
  const swapPaths = [weth, fsm.address];
  await execute(
    'Pool',
    {from: deployer, log: true},
    'configSwap',
    swapRouter,
    swapSlippage,
    swapPaths
  );
};

func.tags = ['farm'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
