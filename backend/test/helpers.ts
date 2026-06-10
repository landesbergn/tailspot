/**
 * Test helper: fetch a Map entry that the test asserts must exist, throwing a
 * descriptive error if it doesn't. Lets the suite avoid non-null assertions
 * (`!`) — which biome forbids — while keeping a missing key a loud failure
 * rather than a silent `undefined` propagating into a confusing assertion.
 */
export function mustGet<K, V>(map: Map<K, V>, key: K): V {
  const v = map.get(key);
  if (v === undefined) {
    throw new Error(`expected map to contain key ${String(key)}`);
  }
  return v;
}
