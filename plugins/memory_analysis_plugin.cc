#include "plugin.h"
#include "inc/memory_analysis_wrapper.h"

extern "C"{
    PUBLIC_API void getMessageHandlers(const std::string& kernel, uint64_t dispatch_id, std::vector<dh_comms::message_handler_base *>& outHandlers)
    {
        std::string location = "console";
        const char* logDurLogLocation = std::getenv("LOGDUR_LOG_LOCATION");
        if (logDurLogLocation != NULL)
            location = logDurLogLocation;

        // Read verbose setting from environment
        bool verbose = false;
        const char* logDurVerbose = std::getenv("LOGDUR_VERBOSE");
        if (logDurVerbose != NULL && (strcmp(logDurVerbose, "1") == 0 || strcmp(logDurVerbose, "true") == 0)) {
            verbose = true;
        }
        
        outHandlers.push_back(new memory_analysis_wrapper_t(kernel, dispatch_id, location, verbose));
    }
}
