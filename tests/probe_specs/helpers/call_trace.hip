#include <stdint.h>

using namespace omniprobe::probe_abi_v1;

namespace {

struct call_trace_record {
  uint64_t timestamp;
  uint32_t callee_id;
  uint32_t event;
};

}  // namespace

extern "C" __device__ void call_trace_probe(
    const helper_args<omniprobe_user::call_trace_captures, call_event> &args) {
  call_trace_record record{};
  record.timestamp = args.event->timestamp;
  record.callee_id = args.event->callee_id;
  record.event = static_cast<uint32_t>(args.site->event);
  dh_comms::s_submit_message(args.runtime->dh, &record, sizeof(record), false, 0,
                             4401, 0, 0x4f500100u, args.event->callee_id,
                             args.runtime->dh_builtins);
}
