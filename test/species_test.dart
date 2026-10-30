import 'package:egg_incubator/species.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown species falls back to chicken', () {
    expect(speciesById('dragon').id, 'chicken');
    expect(speciesById('duck').days, 28);
  });

  test('lockdown comes before hatch day', () {
    for (final s in allSpecies) {
      expect(s.lockdownDay, lessThan(s.days));
    }
  });
}
