# frozen_string_literal: true

require "test_helper"

module Raptor
  class TestCluster < TestCase
    parallelize_me!

    def test_default_http1_ractor_count_returns_1_when_workers_match_cores
      assert_equal 1, Cluster.default_http1_ractor_count(10, cores: 10)
    end

    def test_default_http1_ractor_count_returns_1_when_workers_exceed_cores
      assert_equal 1, Cluster.default_http1_ractor_count(20, cores: 10)
    end

    def test_default_http1_ractor_count_scales_with_cores_per_worker
      assert_equal 2, Cluster.default_http1_ractor_count(10, cores: 20)
    end

    def test_default_http1_ractor_count_rounds_half_up
      assert_equal 2, Cluster.default_http1_ractor_count(10, cores: 15)
    end

    def test_default_http1_ractor_count_clamps_to_upper_bound
      assert_equal Cluster::HTTP1_RACTOR_COUNT_CAP, Cluster.default_http1_ractor_count(4, cores: 40)
    end

    def test_default_http2_ractor_count_returns_1_when_workers_match_cores
      assert_equal 1, Cluster.default_http2_ractor_count(10, cores: 10)
    end

    def test_default_http2_ractor_count_returns_1_when_workers_exceed_cores
      assert_equal 1, Cluster.default_http2_ractor_count(20, cores: 10)
    end

    def test_default_http2_ractor_count_scales_with_cores_per_worker
      assert_equal 2, Cluster.default_http2_ractor_count(10, cores: 20)
    end

    def test_default_http2_ractor_count_rounds_half_up
      assert_equal 2, Cluster.default_http2_ractor_count(10, cores: 15)
    end

    def test_default_http2_ractor_count_clamps_to_upper_bound
      assert_equal Cluster::HTTP2_RACTOR_COUNT_CAP, Cluster.default_http2_ractor_count(4, cores: 40)
    end
  end
end
