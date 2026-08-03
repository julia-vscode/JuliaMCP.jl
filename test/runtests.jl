using TestItemRunner

# Only run test items that live in this directory — `testdata/` intentionally
# contains `@testitem`s that are fixtures, not tests of this package.
@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, ""))
