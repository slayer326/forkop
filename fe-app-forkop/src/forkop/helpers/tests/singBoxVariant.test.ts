import { describe, expect, it } from 'vitest';
import {
  formatSingBoxVersion,
  isPodkopEngineSingBoxVersion,
  normalizeSingBoxVariantFields,
} from '../singBoxVariant';

type Fields = {
  sing_box_version: string;
  sing_box_extended?: number;
  sing_box_tiny?: number;
  sing_box_podkop_engine?: number;
  sing_box_podkop_engine_full?: number;
};

describe('podkop-engine sing-box variant', () => {
  it('is recognised by its -pdk- version', () => {
    expect(isPodkopEngineSingBoxVersion('1.14.3-pdk-r16')).toBe(true);
    expect(isPodkopEngineSingBoxVersion('1.14.3-extended-2.7.3')).toBe(false);
    expect(isPodkopEngineSingBoxVersion('1.14.3')).toBe(false);
  });

  it('overrides a stale tiny flag', () => {
    const value = normalizeSingBoxVariantFields<Fields>({
      sing_box_version: '1.14.3-pdk-r16',
      sing_box_tiny: 1,
    });

    expect(value.sing_box_podkop_engine).toBe(1);
    expect(value.sing_box_podkop_engine_full).toBe(0);
    expect(value.sing_box_tiny).toBe(0);
    expect(value.sing_box_extended).toBe(0);
  });

  it('keeps the full package apart from the slim one', () => {
    expect(
      formatSingBoxVersion({
        sing_box_version: '1.14.3-pdk-r16',
        sing_box_podkop_engine: 1,
        sing_box_podkop_engine_full: 1,
      }),
    ).toBe('1.14.3-pdk-r16 (podkop-engine-full)');
    expect(
      formatSingBoxVersion({
        sing_box_version: '1.14.3-pdk-r16',
        sing_box_podkop_engine: 1,
      }),
    ).toBe('1.14.3-pdk-r16 (podkop-engine)');
  });

  it('never marks sing-box-extended as podkop-engine', () => {
    const value = normalizeSingBoxVariantFields<Fields>({
      sing_box_version: '1.14.3-extended-2.7.3',
      sing_box_podkop_engine: 1,
    });

    expect(value.sing_box_extended).toBe(1);
    expect(value.sing_box_podkop_engine).toBe(0);
  });
});
