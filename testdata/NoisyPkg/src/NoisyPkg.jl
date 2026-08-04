module NoisyPkg

deep(n) = n <= 0 ? error("boom at the bottom") : deep(n - 1)

end
