/// The balanced score. Imported by both the app and the tests: if the §15
/// tests fail, tune [balancedTimeWeight], never the test invariants.
library;

const balancedTimeWeight = 2.0;
const detourPenalty = 150.0;

double score({
  required double walkMetres,
  required double durationMinutes,
  bool detoured = false,
}) =>
    walkMetres +
    balancedTimeWeight * durationMinutes +
    (detoured ? detourPenalty : 0);
