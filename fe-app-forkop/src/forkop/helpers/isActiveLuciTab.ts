import { activeForkopController } from '../services/forkopPage';

// Whether this controller is the one in front, and so may poll and render.
export function isActiveLuciTab(tabId: string) {
  return activeForkopController() === tabId;
}
