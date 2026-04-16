using namespace omniprobe::probe_abi_v1;

extern "C" __device__ void memory_trace_probe(
    const helper_args<omniprobe_user::memory_trace_captures,
                      memory_op_event> &args) {
  dh_comms::v_submit_address(
      args.runtime->dh, reinterpret_cast<void *>(args.event->address), 0, 4101,
      0, static_cast<uint8_t>(args.event->access),
      static_cast<uint8_t>(args.event->address_space),
      static_cast<uint16_t>(args.event->bytes));
}
