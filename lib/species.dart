/// Incubation presets. Humidity is the usual range; lockdown is the last few days before hatching,
/// when turning stops and humidity goes up.
class Species {
  final String id;
  final int days;
  final int lockdownDay;
  final double temp;
  final int hMin, hMax;
  final int lockMin, lockMax;

  const Species(this.id, this.days, this.lockdownDay, this.temp, this.hMin, this.hMax, this.lockMin, this.lockMax);
}

const allSpecies = [
  Species('chicken', 21, 18, 37.5, 50, 55, 65, 70),
  Species('duck', 28, 25, 37.5, 55, 60, 70, 75),
  Species('quail', 18, 15, 37.5, 45, 50, 65, 70),
  Species('goose', 30, 27, 37.4, 50, 55, 75, 80),
  Species('turkey', 28, 25, 37.5, 50, 55, 65, 70),
];

Species speciesById(String? id) => allSpecies.firstWhere((s) => s.id == id, orElse: () => allSpecies.first);
