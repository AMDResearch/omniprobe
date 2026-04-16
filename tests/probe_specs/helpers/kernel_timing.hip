#include "time_interval_handler.h"

using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void kernel_timing_probe(
    const helper_args<omniprobe_user::kernel_timing_captures,
                      kernel_lifecycle_event> &args) {
  if (blockIdx.x != 0 || blockIdx.y != 0 || blockIdx.z != 0 || threadIdx.x != 0 ||
      threadIdx.y != 0 || threadIdx.z != 0) {
    return;
  }

  dh_comms::time_interval stamp{};
  stamp.start = args.event->timestamp;
  stamp.stop = args.event->timestamp;
  const uint32_t tag =
      args.site->event == event_kind::kernel_entry ? 0x1001u : 0x1002u;
  dh_comms::s_submit_time_interval(args.runtime->dh, &stamp, 0, 4201, 0, tag);
}
