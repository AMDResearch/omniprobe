#pragma once
#include "message_handlers.h"
#include "memory_analysis_handler.h"

#include <map>
#include <set>
#include <vector>

class memory_analysis_wrapper_t : public dh_comms::message_handler_base {
public:
  memory_analysis_wrapper_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& strLocation, bool verbose);
  virtual ~memory_analysis_wrapper_t() = default;
  virtual bool handle(const dh_comms::message_t &message) override;
  virtual bool handle(const dh_comms::message_t &message, const std::string& kernel, kernelDB::kernelDB& kdb) override;
  virtual void report(const std::string& kernel_name, kernelDB::kernelDB& kdb) override;
  virtual void report() override;
  virtual void clear() override;

  const std::string& kernel_;
  uint64_t dispatch_id_;
  const std::string& location_;
  dh_comms::memory_analysis_handler_t wrapped_;
};
