// MIT License
//
// Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include "inc/time_interval_handler.h"

#include <cassert>

namespace dh_comms {

time_interval_handler_t::time_interval_handler_t(const std::string& strKernel, uint64_t dispatch_id, const std::string& location, bool verbose /*= false*/) : kernel_(strKernel), dispatch_id_(dispatch_id), location_(location),
  first_start_(0xffffffffffffffff),
  last_stop_(0),
  total_time_(0),
  no_intervals_(0),
  verbose_(verbose)
{
    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat)
        format_ = logDurLogFormat;
    else
        format_= "csv";
}

time_interval_handler_t::time_interval_handler_t(bool verbose)
    : first_start_(0xffffffffffffffff),
      last_stop_(0),
      total_time_(0),
      no_intervals_(0),
      verbose_(verbose) 
{

    const char* logDurLogFormat= std::getenv("LOGDUR_LOG_FORMAT");
    if (logDurLogFormat)
        format_ = logDurLogFormat;
    else
        format_= "csv";

}

time_interval_handler_t::~time_interval_handler_t()
{
    if(location_ != "console")
        delete log_file_;
}

  
bool time_interval_handler_t::handle(const message_t &message) {
  if (message.wave_header().user_type != message_type::time_interval) {
    if (verbose_) {
      printf("time_interval_handler: skipping message with user type 0x%x\n", message.wave_header().user_type);
    }
    return false;
  }
  assert(message.data_item_size() == sizeof(time_interval));
  for (size_t i = 0; i != message.no_data_items(); ++i) {
    time_interval ti = *(const time_interval *)message.data_item(i);
    assert(ti.start <= ti.stop);

    first_start_ = ti.start < first_start_ ? ti.start : first_start_;
    last_stop_ = ti.stop > last_stop_ ? ti.stop : last_stop_;
    total_time_ += ti.stop - ti.start;
    ++no_intervals_;
    if (verbose_) {
      printf("time_interval processed:\n");
      printf("\tstart = %lu\n", ti.start);
      printf("\tstop = %lu\n", ti.stop);
    }
  }
  return true;
}

void time_interval_handler_t::setupLogger()
{
    if (location_ == "console")
        log_file_ = &std::cout;
    else
        log_file_ = new std::ofstream(location_, std::ios::app);
}




void time_interval_handler_t::report() {
    setupLogger();
    if (format_ != "json")
    {
      if (no_intervals_ != 0) {
        double average_time = (double)total_time_ / no_intervals_;
        *log_file_ << "time_interval report:\n";
        *log_file_ << "\ttotal time for all " << no_intervals_ << " intervals: " << total_time_ << std::endl;
        *log_file_ << "\taverage time per interval: " << average_time << std::endl;
        *log_file_ << "\tfirst start: " << first_start_ << std::endl;
        *log_file_ << "\tlast stop: " << last_stop_ << std::endl; 
        *log_file_ << "\ttime from first start to last stop: " << last_stop_ - first_start_;
        *log_file_ << "\t   (" << (last_stop_ - first_start_) / average_time << " times the average interval time)" << std::endl;
      }
  }
}

void time_interval_handler_t::clear() {
  first_start_ = 0;
  last_stop_ = 0;
  total_time_ = 0;
  no_intervals_ = 0;
}

} // namespace dh_comms
