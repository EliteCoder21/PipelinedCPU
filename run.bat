@echo off
REM CSE 469 Docker Run Script for Windows
REM Usage: run.bat [workspace_path]
REM
REM If no path specified, mounts current directory as workspace.

setlocal

REM Default to current directory
set WORKSPACE_PATH=%1
if "%WORKSPACE_PATH%"=="" set WORKSPACE_PATH=.

REM Image name - change this after publishing to Docker Hub
set IMAGE_NAME=therapy9903/cse469-tools:latest
REM set IMAGE_NAME=YOUR_DOCKERHUB_USERNAME/cse469-tools:latest

REM Get absolute path
for %%i in ("%WORKSPACE_PATH%") do set ABS_WORKSPACE=%%~fi

echo ========================================
echo CSE 469 Development Environment
echo Current Path: %ABS_WORKSPACE%
echo Your files are mounted at: /home/student/workspace
echo Type 'exit' to leave the container

REM Run the container
docker run -it --rm ^
    -v "%ABS_WORKSPACE%":/home/student/workspace ^
    -w /home/student/workspace ^
    %IMAGE_NAME%

endlocal