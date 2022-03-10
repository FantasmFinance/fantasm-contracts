import {constants} from 'ethers';
import {network} from 'hardhat';
import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts, wellknown}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  console.log('> deployer', deployer);
  console.log('> Network name:' + network.name);
  console.log('> wellknow:' + JSON.stringify(wellknown));
  console.log((wellknown as any)[network.name].addresses);

  const weth = {address: (wellknown as any)[network.name].addresses.weth};

  const farm = await get('FantasticChef');
  const fsm = await get('FSM');
  const reserve = await get('FsmReserve');
  const wethUtils = await get('WethUtils');

  const staking = await deploy('FantasticStaking', {
    from: deployer,
    log: true,
    args: [fsm.address, reserve.address, [farm.address]],
    libraries: {
      WethUtils: wethUtils.address,
    },
  });

  await execute('FantasticChef', {from: deployer, log: true}, 'setRewardMinter', staking.address);

  const treasury = await deploy('FantasticTreasury', {
    from: deployer,
    log: true,
    args: [staking.address],
  });

  await execute(
    'FantasticStaking',
    {from: deployer, log: true},
    'addReward',
    weth.address,
    treasury.address
  );
};

func.tags = ['staking'];

func.skip = async ({network}) => {
  return network.name !== 'avax';
};

export default func;
