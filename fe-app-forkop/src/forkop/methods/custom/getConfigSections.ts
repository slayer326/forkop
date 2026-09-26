import { Forkop } from '../../types';
import { FORKOP_UCI_PACKAGE } from '../../../constants';
import { ForkopShellMethods } from '../shell';

export async function getConfigSections(): Promise<Forkop.ConfigSection[]> {
  try {
    await uci.load(FORKOP_UCI_PACKAGE);
    return await uci.sections(FORKOP_UCI_PACKAGE);
  } catch (_error) {
    const response = await ForkopShellMethods.getReadonlyConfigSections();
    return response.success ? response.data : [];
  }
}
