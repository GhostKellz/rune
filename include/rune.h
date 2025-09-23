/**
 * Rune FFI Interface Header
 * C ABI for integrating Rune (Zig MCP library) with Glyph (Rust MCP server)
 *
 * This header provides the C-compatible interface that allows Rust applications
 * to leverage Rune's high-performance MCP tool implementations.
 */

#ifndef RUNE_H
#define RUNE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

//-----------------------------------------------------------------------------
// Version Information
//-----------------------------------------------------------------------------

#define RUNE_VERSION_MAJOR 0
#define RUNE_VERSION_MINOR 1
#define RUNE_VERSION_PATCH 0

//-----------------------------------------------------------------------------
// Error Codes
//-----------------------------------------------------------------------------

typedef enum RuneError {
    RUNE_SUCCESS = 0,
    RUNE_INVALID_ARGUMENT = -1,
    RUNE_OUT_OF_MEMORY = -2,
    RUNE_TOOL_NOT_FOUND = -3,
    RUNE_EXECUTION_FAILED = -4,
    RUNE_VERSION_MISMATCH = -5,
    RUNE_THREAD_SAFETY_VIOLATION = -6,
    RUNE_IO_ERROR = -7,
    RUNE_PERMISSION_DENIED = -8,
    RUNE_TIMEOUT = -9,
    RUNE_UNKNOWN_ERROR = -99,
} RuneError;

//-----------------------------------------------------------------------------
// Opaque Handle Types
//-----------------------------------------------------------------------------

typedef struct RuneHandle RuneHandle;
typedef struct RuneToolHandle RuneToolHandle;
typedef struct RuneResultHandle RuneResultHandle;

//-----------------------------------------------------------------------------
// Structure Definitions
//-----------------------------------------------------------------------------

typedef struct RuneResult {
    bool success;
    RuneError error_code;
    const char* data;
    size_t data_len;
    const char* error_message;
    size_t error_len;
} RuneResult;

typedef struct RuneVersion {
    uint32_t major;
    uint32_t minor;
    uint32_t patch;
} RuneVersion;

typedef struct RuneToolInfo {
    const char* name;
    size_t name_len;
    const char* description;
    size_t description_len;
} RuneToolInfo;

//-----------------------------------------------------------------------------
// Callback Function Types
//-----------------------------------------------------------------------------

typedef void (*RuneCallback)(void* user_data, const RuneResult* result);
typedef void (*RuneProgressCallback)(void* user_data, float progress, const char* message);

//-----------------------------------------------------------------------------
// Core FFI Functions
//-----------------------------------------------------------------------------

/**
 * Initialize the Rune engine
 * @return Handle to the Rune instance, or NULL on failure
 */
RuneHandle* rune_init(void);

/**
 * Cleanup the Rune engine and free all resources
 * @param handle The Rune handle to cleanup
 */
void rune_cleanup(RuneHandle* handle);

/**
 * Get Rune version information
 * @return Version structure
 */
RuneVersion rune_get_version(void);

//-----------------------------------------------------------------------------
// Tool Management Functions
//-----------------------------------------------------------------------------

/**
 * Register a tool with the Rune engine
 * @param handle Rune engine handle
 * @param name Tool name (UTF-8 string)
 * @param name_len Length of tool name in bytes
 * @param description Tool description (optional, can be NULL)
 * @param description_len Length of description in bytes
 * @return Error code (RUNE_SUCCESS on success)
 */
RuneError rune_register_tool(
    RuneHandle* handle,
    const char* name,
    size_t name_len,
    const char* description,
    size_t description_len
);

/**
 * Get the number of registered tools
 * @param handle Rune engine handle
 * @return Number of tools, or 0 on error
 */
size_t rune_get_tool_count(RuneHandle* handle);

/**
 * Get information about a registered tool by index
 * @param handle Rune engine handle
 * @param index Tool index (0-based)
 * @param out_info Pointer to RuneToolInfo structure to fill
 * @return Error code (RUNE_SUCCESS on success)
 */
RuneError rune_get_tool_info(
    RuneHandle* handle,
    size_t index,
    RuneToolInfo* out_info
);

//-----------------------------------------------------------------------------
// Tool Execution Functions
//-----------------------------------------------------------------------------

/**
 * Execute a tool synchronously
 * @param handle Rune engine handle
 * @param name Tool name (UTF-8 string)
 * @param name_len Length of tool name in bytes
 * @param params_json JSON parameters as string (can be NULL for no params)
 * @param params_len Length of params JSON in bytes
 * @return Result handle (must be freed with rune_free_result), or NULL on error
 */
RuneResultHandle* rune_execute_tool(
    RuneHandle* handle,
    const char* name,
    size_t name_len,
    const char* params_json,
    size_t params_len
);

/**
 * Execute a tool asynchronously with callback
 * @param handle Rune engine handle
 * @param name Tool name (UTF-8 string)
 * @param name_len Length of tool name in bytes
 * @param params_json JSON parameters as string (can be NULL for no params)
 * @param params_len Length of params JSON in bytes
 * @param callback Function to call when execution completes
 * @param user_data User data passed to callback
 * @return Error code (RUNE_SUCCESS on success)
 */
RuneError rune_execute_tool_async(
    RuneHandle* handle,
    const char* name,
    size_t name_len,
    const char* params_json,
    size_t params_len,
    RuneCallback callback,
    void* user_data
);

//-----------------------------------------------------------------------------
// Memory Management Functions
//-----------------------------------------------------------------------------

/**
 * Free a result handle and all associated memory
 * @param handle Result handle to free
 */
void rune_free_result(RuneResultHandle* handle);

/**
 * Allocate memory using Rune's allocator
 * Useful when passing data from Rust to Rune
 * @param size Number of bytes to allocate
 * @return Pointer to allocated memory, or NULL on failure
 */
void* rune_alloc(size_t size);

/**
 * Free memory allocated by rune_alloc
 * @param ptr Pointer to memory to free
 * @param size Size of the allocation (must match allocation size)
 */
void rune_free(void* ptr, size_t size);

//-----------------------------------------------------------------------------
// Utility Functions
//-----------------------------------------------------------------------------

/**
 * Get the last error message for the current thread
 * @return Error message string, or NULL if no error
 */
const char* rune_get_last_error(void);

//-----------------------------------------------------------------------------
// Convenience Macros
//-----------------------------------------------------------------------------

/**
 * Check if a Rune operation was successful
 */
#define RUNE_SUCCEEDED(err) ((err) == RUNE_SUCCESS)

/**
 * Check if a Rune operation failed
 */
#define RUNE_FAILED(err) ((err) != RUNE_SUCCESS)

/**
 * Convert RuneResult to success boolean
 */
#define RUNE_RESULT_SUCCEEDED(result) ((result) && (result)->success)

/**
 * Get data from successful RuneResult as string
 */
#define RUNE_RESULT_DATA(result) \
    (RUNE_RESULT_SUCCEEDED(result) ? (result)->data : NULL)

/**
 * Get data length from successful RuneResult
 */
#define RUNE_RESULT_DATA_LEN(result) \
    (RUNE_RESULT_SUCCEEDED(result) ? (result)->data_len : 0)

/**
 * Get error message from failed RuneResult
 */
#define RUNE_RESULT_ERROR(result) \
    ((!RUNE_RESULT_SUCCEEDED(result) && (result)->error_message) ? (result)->error_message : NULL)

#ifdef __cplusplus
}
#endif

#endif /* RUNE_H */