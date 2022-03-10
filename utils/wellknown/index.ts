import {extendEnvironment} from 'hardhat/config';
import {lazyObject} from 'hardhat/plugins';
import {wellknown} from './lib';

import './types';

extendEnvironment((hre) => {
  hre.wellknown = lazyObject(() => wellknown);
});
