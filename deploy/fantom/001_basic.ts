import {DeployFunction} from 'hardhat-deploy/dist/types';

const func: DeployFunction = async ({deployments, getNamedAccounts}) => {
  const {deploy, get, execute} = deployments;
  const {deployer} = await getNamedAccounts();

  const xftm = await deploy('XFTM', {
    contract: 'XFTM',
    from: deployer,
    log: true,
  });

  const fsm = await deploy('Fantasm', {
    contract: 'Fantasm',
    from: deployer,
    log: true,
    args: [],
  });

  await deploy('DevFund', {
    from: deployer,
    log: true,
    args: [fsm.address],
  });

  await deploy('TreasuryFund', {
    from: deployer,
    log: true,
    args: [fsm.address],
  });

  const wethUtils = await get('WethUtils');

  await deploy('Pool', {
    from: deployer,
    log: true,
    args: [xftm.address, fsm.address],
    libraries: {
      WethUtils: wethUtils.address,
    },
  });
};

func.tags = ['base'];

func.skip = async ({network}) => {
  return network.name !== 'fantom';
};

export default func;
