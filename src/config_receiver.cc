/******************************************************************************
Copyright (c) 2026 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*******************************************************************************/
#include "inc/config_receiver.h"
#include <openssl/bio.h>
#include <openssl/err.h>
#include <stdexcept>
#include <vector>

ConfigReceiver::ConfigReceiver(const std::string& endpoint, const std::string& public_key_pem)
    : context_(), socket_(context_, zmqpp::socket_type::subscribe) {
    // Connect to ZeroMQ endpoint
    socket_.set(zmqpp::socket_option::subscribe, ""); // Subscribe to all messages
    socket_.connect(endpoint);

    // Initialize public key
    init_public_key(public_key_pem);
}

ConfigReceiver::~ConfigReceiver() {
    EVP_PKEY_free(public_key_);
}

void ConfigReceiver::init_public_key(const std::string& public_key_pem) {
    BIO* bio = BIO_new_mem_buf(public_key_pem.data(), public_key_pem.size());
    if (!bio) {
        throw std::runtime_error("Failed to create BIO for public key");
    }

    public_key_ = PEM_read_bio_PUBKEY(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);

    if (!public_key_) {
        throw std::runtime_error("Failed to load public key: " + std::string(ERR_error_string(ERR_get_error(), nullptr)));
    }
}

json ConfigReceiver::receive_config() {
    zmqpp::message_t message;
    if (!socket_.receive(message)) {
        throw std::runtime_error("Failed to receive message");
    }

    // Parse JSON
    std::string msg_str;
    size_t parts = message.parts();
    for (size_t part = 0; part < message.parts(); part++)
        msg_str += message.get(part);
    json config;
    try {
        config = json::parse(msg_str);
    } catch (const json::exception& e) {
        throw std::runtime_error("JSON parsing failed: " + std::string(e.what()));
    }

    // Extract and remove signature from JSON
    if (!config.contains("signature") || !config["signature"].is_string()) {
        throw std::runtime_error("Missing or invalid signature in JSON");
    }
    std::string signature_b64 = config["signature"];
    config.erase("signature");

    // Verify signature
    if (!verify_signature(config, signature_b64)) {
        throw std::runtime_error("Signature verification failed");
    }

    return config;
}

bool ConfigReceiver::verify_signature(const json& config, const std::string& signature_b64) {
    // Serialize JSON for signing (canonical form)
    std::string config_str = config.dump();

    // Decode base64 signature using OpenSSL
    std::vector<unsigned char> signature;
    BIO* b64 = BIO_new(BIO_f_base64());
    BIO* bio = BIO_new_mem_buf(signature_b64.data(), signature_b64.size());
    bio = BIO_push(b64, bio);

    // Configure BIO to handle base64 decoding
    BIO_set_flags(bio, BIO_FLAGS_BASE64_NO_NL);
    std::vector<unsigned char> buffer(1024); // Buffer for decoded data
    int decoded_len = 0;
    signature.resize(signature_b64.size()); // Preallocate for worst case

    while (true) {
        int read_len = BIO_read(bio, buffer.data(), buffer.size());
        if (read_len <= 0) break;
        if (decoded_len + read_len > signature.size()) {
            signature.resize(decoded_len + read_len);
        }
        std::copy(buffer.begin(), buffer.begin() + read_len, signature.begin() + decoded_len);
        decoded_len += read_len;
    }
    signature.resize(decoded_len);

    BIO_free_all(bio);
    if (decoded_len == 0) {
        throw std::runtime_error("Base64 decode failed");
    }

    // Initialize digest
    EVP_MD_CTX* md_ctx = EVP_MD_CTX_new();
    if (!md_ctx) {
        throw std::runtime_error("Failed to create EVP_MD_CTX");
    }

    bool verified = false;
    if (EVP_DigestVerifyInit(md_ctx, nullptr, EVP_sha256(), nullptr, public_key_) &&
        EVP_DigestVerifyUpdate(md_ctx, config_str.data(), config_str.size())) {
        int result = EVP_DigestVerifyFinal(md_ctx, signature.data(), signature.size());
        verified = (result == 1);
    }

    EVP_MD_CTX_free(md_ctx);
    return verified;
}
