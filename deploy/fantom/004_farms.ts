import {constants} from 'ethers';
import {network} from 'hardhat';
import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts, wellknown}) => {
  const {deploy, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  console.log('> deployer', deployer);
  console.log('> Network name:' + network.name);
  console.log('> wellknow:' + JSON.stringify(wellknown));
  console.log((wellknown as any)[network.name].addresses);

  const lp_xftm_eth = {address: (wellknown as any)[network.name].addresses.xTokenEth};
  const lp_fsm_eth = {address: (wellknown as any)[network.name].addresses.yTokenEth};

  await deploy('FantasticChef', {
    from: deployer,
    log: true,
  });

  await execute(
    'FantasticChef',
    {from: deployer, log: true},
    'add',
    30000,
    lp_fsm_eth.address,
    constants.AddressZero
  );

  await execute(
    'FantasticChef',
    {from: deployer, log: true},
    'add',
    70000,
    lp_xftm_eth.address,
    constants.AddressZero
  );
};

func.tags = ['farm'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
