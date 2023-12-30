#pragma once
#ifndef __CUDAJPEG_H_

    #include <algorithm>
    #include <cstdint>
    #include <cstdio>
    #include <cstring> // strcmpi
    #include <fstream>
    #include <sstream>
    #include <string>
    #include <vector>

    #if (defined _WIN32) || (defined _WIN64)
        #define _AMD64_      // target arch
        #define WIN32_LEAN_AND_MEAN
        #define WIN32_EXTRA_MEAN
        #include <fileapi.h> // WIN32 alternative of <dirnet.h>
        #include <handleapi.h>
    #endif

    #include <cuda_runtime_api.h>
    #include <nppi_geometry_transforms.h>
    #include <nvjpeg.h>

    #define CHECK_CUDA(call)                                                                                                               \
        {                                                                                                                                  \
            cudaError_t _e = (call);                                                                                                       \
            if (_e != cudaSuccess) {                                                                                                       \
                std::cout << "CUDA Runtime failure: '#" << _e << "' at " << __FILE__ << ":" << __LINE__ << std::endl;                      \
                exit(1);                                                                                                                   \
            }                                                                                                                              \
        }

    #define CHECK_NVJPEG(call)                                                                                                             \
        {                                                                                                                                  \
            nvjpegStatus_t _e = (call);                                                                                                    \
            if (_e != NVJPEG_STATUS_SUCCESS) {                                                                                             \
                std::cout << "NVJPEG failure: '#" << _e << "' at " << __FILE__ << ":" << __LINE__ << std::endl;                            \
                exit(1);                                                                                                                   \
            }                                                                                                                              \
        }

struct image_resize_params_t {
        std::string input_dir {};
        std::string output_dir {};
        int32_t     quality {};
        int32_t     width {};
        int32_t     height {};
        int32_t     dev {};
};

struct {
        NppiSize      size {};
        nvjpegImage_t data {};
} image_t;

[[msvc::forceinline]] static int32_t __stdcall dev_malloc(_In_ void** p, _In_ const size_t s) { return (int) cudaMalloc(p, s); }

[[msvc::forceinline]] static int32_t __stdcall dev_free(_In_ void* p) { return (int) cudaFree(p); }

[[msvc::forceinline]] static bool __stdcall is_interleaved(nvjpegOutputFormat_t format) noexcept {
    return (format == NVJPEG_OUTPUT_RGBI || format == NVJPEG_OUTPUT_BGRI) ? true : false;
}

// *****************************************************************************
// reading input directory to file list
// -----------------------------------------------------------------------------
int readInput(_In_ const std::wstring& sInputPath, _Inout_ std::vector<std::string>& filelist) noexcept {
    int         error_code = 1;
    struct stat s;

    HANDLE      hPath { ::CreateFileW(sInputPath.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr) };
    if (hPath == INVALID_HANDLE_VALUE)
        ;
    WIN32_FIND_DATAW           fdFindData {};
    BY_HANDLE_FILE_INFORMATION bhfiPathInfo {};
    HANDLE                     hFile {};
    GetFileInformationByHandle(hPath, &bhfiPathInfo);

    if (bhfiPathInfo.dwFileAttributes & FILE_ATTRIBUTE_NORMAL) { }
    if (bhfiPathInfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        ;
        hFile = ::FindFirstFileExW(
            sInputPath.c_str(), FindExInfoStandard, &fdFindData, FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH
        );
    }

    if (stat(sInputPath.c_str(), &s) == 0) {
        if (s.st_mode & S_IFREG) {
            filelist.push_back(sInputPath);
        } else if (s.st_mode & S_IFDIR) {
            // processing each file in directory
            DIR*           dir_handle;
            struct dirent* dir;
            dir_handle = opendir(sInputPath.c_str());
            std::vector<std::string> filenames;
            if (dir_handle) {
                error_code = 0;
                while ((dir = readdir(dir_handle)) != NULL) {
                    if (dir->d_type == DT_REG) {
                        std::string sFileName = sInputPath + dir->d_name;
                        filelist.push_back(sFileName);
                    } else if (dir->d_type == DT_DIR) {
                        std::string sname = dir->d_name;
                        if (sname != "." && sname != "..") readInput(sInputPath + sname + "/", filelist);
                    }
                }
                closedir(dir_handle);
            } else {
                std::cout << "Cannot open input directory: " << sInputPath << std::endl;
                return error_code;
            }
        } else {
            std::cout << "Cannot open input: " << sInputPath << std::endl;
            return error_code;
        }
    } else {
        std::cout << "Cannot find input path " << sInputPath << std::endl;
        return error_code;
    }

    return 0;
}

// *****************************************************************************
// check for inputDirExists
// -----------------------------------------------------------------------------
bool inputDirExists(_In_ const char* const pathname) {
    struct stat info;
    if (stat(pathname, &info) != 0) {
        return 0; // Directory does not exists
    } else if (info.st_mode & S_IFDIR) {
        // is a directory
        return 1;
    } else {
        // is not a directory
        return 0;
    }
}

// *****************************************************************************
// check for getInputDir
// -----------------------------------------------------------------------------
int getInputDir(std::string& input_dir, const char* executable_path) {
    int found = 0;
    if (executable_path != 0) {
        std::string executable_name = std::string(executable_path);

        // Windows path delimiter
        size_t      delimiter_pos   = executable_name.find_last_of('\\');
        executable_name.erase(0, delimiter_pos + 1);

        if (executable_name.rfind(".exe") != std::string::npos) {
            // we strip .exe, only if the .exe is found
            executable_name.resize(executable_name.size() - 4);
        }

        // Search in default paths for input images.
        std::string pathname     = "";
        const char* searchPath[] = { "./images" };

        for (unsigned int i = 0; i < sizeof(searchPath) / sizeof(char*); ++i) {
            std::string pathname(searchPath[i]);
            size_t      executable_name_pos = pathname.find("<executable_name>");

            // If there is executable_name variable in the searchPath
            // replace it with the value
            if (executable_name_pos != std::string::npos)
                pathname.replace(executable_name_pos, strlen("<executable_name>"), executable_name);

            if (inputDirExists(pathname.c_str())) {
                input_dir = pathname + "/";
                found     = 1;
                break;
            }
        }
    }
    return found;
}

// *****************************************************************************
// parse parameters
// -----------------------------------------------------------------------------
int findParamIndex(const char** argv, int argc, const char* parm) {
    int count = 0;
    int index = -1;

    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], parm, 100) == 0) {
            index = i;
            count++;
        }
    }

    if (count == 0 || count == 1) {
        return index;
    } else {
        std::cout << "Error, parameter " << parm << " has been specified more than once, exiting\n" << std::endl;
        return -1;
    }

    return -1;
}

#endif // ! __CUDAJPEG_H_