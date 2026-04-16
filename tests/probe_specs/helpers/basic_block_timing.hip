#include "time_interval_handler.h"

using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void basic_block_timing_probe(
    const helper_args<omniprobe_user::basic_block_timing_captures,
                      basic_block_event> &args) {
  if (threadIdx.x != 0 || threadIdx.y != 0 || threadIdx.z != 0) {
    return;
  }

  dh_comms::time_interval stamp{};
  stamp.start = args.event->timestamp;
  stamp.stop = args.event->timestamp;
  dh_comms::s_submit_time_interval(args.runtime->dh, &stamp, 0, 4301, 0,
                                   args.event->block_id);
}
