module SyncRecordWatch
  # Response-time histogram with fixed bucket bounds (milliseconds), so Sync Record Watch can
  # add up histograms from many processes and minutes and still give percentiles.
  # Bucket i counts values <= BOUNDS[i]; the last bucket counts everything slower.
  module Histogram
    BOUNDS = [ 5, 10, 25, 50, 75, 100, 150, 200, 300, 500, 750, 1_000, 1_500, 2_000, 3_000, 5_000, 7_500, 10_000, 20_000 ].freeze
    SIZE = BOUNDS.size + 1

    module_function

    def empty
      Array.new(SIZE, 0)
    end

    def index(ms)
      BOUNDS.bsearch_index { |bound| ms <= bound } || BOUNDS.size
    end
  end
end
