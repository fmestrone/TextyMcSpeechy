#!/bin/bash

RESET='\033[0m' # Reset text color to default
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD_BLACK='\033[1;30m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_PURPLE='\033[1;35m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'
OUTPUT_DIR="./wav"  #default if using ./metadata.csv

declare -a filenames=()
declare -a phrases=()
declare -a recorded=()

# the first item that has no recording (when there are WAV files in the output folder)
no_recording_index=-1
# the number of WAV files in the output folder
has_recordings=0

choose_os_command() {
  # 1. Detect the Operating System
  local os_name
  os_name=$(uname -s)

  # 2. Set command and arguments based on OS
  case "$os_name" in
    Linux*)
      # Linux uses arecord and aplay (ALSA)
      record_cmd="arecord"
      play_cmd="aplay"
      # Flags: format=cd, type=wav, duration=30, rate=44100
      record_pre_args=(-f cd -t wav -d 30 -r 44100)
      ;;
    Darwin*)
      # macOS (Darwin) typically uses 'sox' (command is 'rec' and 'play') or 'ffmpeg'
      # Let's assume 'rec' and 'play' (part of the 'sox' package)
      record_cmd="rec"
      play_cmd="play"
      # Flags for sox/rec are slightly different but achieve the same result
      # -c 2 (stereo), -r 44100 (rate), trim 0 30 (duration)
      record_pre_args=(-c 2 -r 44100)
      record_post_args=(trim 0 30)
      ;;
    *)
      echo "Error: Unsupported OS: $os_name"
      return 1
      ;;
  esac

  # Check if the recording and playing commands exist
  if ! (command -v "$record_cmd" >/dev/null 2>&1 && command -v "$play_cmd" >/dev/null 2>&1); then
    echo "Error: audio library (alsa/sox) required, but not installed.";
    return 1
  fi

  # Check other commands exist
  if ! (command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1); then
    echo "Error: ffmpeg library required, but not installed.";
    return 1
  fi
}

cleanup(){
  echo "Cleaning up processes"
  stty echo
  sleep 1
  stop_recording
  tput cnorm  # Restore cursor
  sleep 1
  exit 1  # Exit with non-zero status to indicate interruption
}

center_text() { 
  COLUMNS=$(tput cols)
  printf "%*s\n" $(( ( $(echo "$*" | wc -c ) + COLUMNS ) / 2 )) "$*"
}

justify_text() {
  local width=$1
  local text=$2

  COLUMNS=$(tput cols)

  # Pad the text to the specified width
  text=$(printf "%-${width}s" "$text")

  # Calculate the center position
  printf "%*s\n" $(( ( ${#text} + COLUMNS ) / 2 )) "$text"
}

check_files() {
  for ((i = 0; i < ${#filenames[@]}; i++)); do
    path="$output_dir/${filenames[i]}"
    if [[ -f "$path" ]]; then
      recorded[i]=true
      ((has_recordings += 1))
    else
      recorded[i]=false
      if [ $no_recording_index -lt 0 ]; then
        no_recording_index=$i
      fi
    fi
  done
}

# Variable to store original terminal settings
original_tty_settings=""

# Function to hide cursor and keypresses
hide_terminal_output() {
  tput civis  # Hide cursor
  stty -echo  # Disable echoing keypresses
}

# Function to restore cursor and keypresses
restore_terminal_output() {
  stty echo
  tput cnorm  # Restore cursor
}

# Function to trim 100 milliseconds from both ends of a .wav file and overwrite the original
trim_wav() {
  local input_file="$1"
  # Check if input file exists
  if [ ! -f "$input_file" ]; then
      echo "Error: File '$input_file' not found."
      return 1
  fi
  # If it's background noise for noise suppression, skip
  if [[ "$(basename "$input_file")" =~ ^_{0,3}(roomtone|(background)?_{0,3}noise)\.wav ]]; then
    return 0
  fi

  return 0

  # use this to remove long silences from audio

  ffmpeg -i input.wav -filter:a \
  "silenceremove= \
  start_periods=999:  \
  start_duration=2:   \
  start_threshold=0.02" \
  output_trimmed_middle.mp3

  local input_file="$1"

  # Check if input file exists
  if [ ! -f "$input_file" ]; then
      echo "Error: File '$input_file' not found."
      return 1
  fi

  # Create a temporary file path
  temp_file="/tmp/trimmed.wav"

  # Get the duration in seconds
  duration=$(ffprobe -i "$input_file" -show_entries format=duration -v quiet -of csv="p=0")

  # Calculate the new duration (original duration minus 0.2 seconds)
  new_duration=$(awk "BEGIN {printf \"%.3f\", $duration - 0.1}")

  # Trim and save to temporary file
  ffmpeg -y -i "$input_file" -ss 00:00:00.050 -t "$new_duration" -c copy "$temp_file" >/dev/null 2>&1

  # Check if ffmpeg command was successful
  if [ $? -ne 0 ]; then
      echo "Error: Failed to trim '$input_file'."
      return 1
  fi
  # remove original file
  rm $input_file

  # Copy temporary file back to original location with original filename
  cp "$temp_file" "$input_file"

  # Clean up temporary file
  rm "$temp_file"
}

# Function to stop recording if running
stop_recording() {
  # Check if recording is in progress and stop it
  if [[ -n "$record_pid" ]]; then
    kill "$record_pid" >/dev/null 2>&1
  fi
}

# Function to load metadata.csv into arrays
load_metadata() {
  local line_number=0

  # Read metadata.csv line by line
  # Make sure files terminate with a new line, or last line will not be processed
  while IFS='|' read -r col1 col2 _; do
    if [ -z "$col1" ] || [ -z "$col2" ]; then
        break
    fi
    ((line_number++))
    index=$((line_number - 1))

    # Create filename with .wav suffix
    filename="${col1}.wav"

    # Create phrase with line number and text
    phrase="${line_number}. ${col2}"

    echo "$line_number: ${filename}   ${phrase}"
    filenames+=("$filename")
    phrases+=("$phrase")
    recorded+=(false) # initialize array to hold recorded status of each item.
  done < "$csv_file"
  arraylength=${#filenames[@]}
}

get_phrase(){
  local phrase=${phrases[$index]}
  echo "$phrase"
}

get_filename(){
  echo "${filenames[$index]}"
}

# Function to handle Enter key press (for 'record_wav') using arecord
start_recording() {
  update_display "Recording - press <space> to stop."

  # Start recording in the background
  # We expand the args array using "${args[@]}" to preserve quoting
  "$record_cmd" "${record_pre_args[@]}" "$output_dir"/"${filenames[$index]}" "${record_post_args[@]}" > /dev/null 2>&1 &
  record_pid=$!

  # Check for immediate failure
  sleep 0.1
  if ! kill -0 $record_pid 2>/dev/null; then
    update_display "Error: Recording failed to start."
    return 1
  fi

  # Wait for 'r' or 'R' keypress to stop recording
  while true; do
    IFS= read -r -n 1 keypress

    if [[ "$keypress" == " " ]]; then
      stop_recording
      recorded[index]=true
      trim_wav "$output_dir"/"$filename" "100"
      break
    fi
  done

}

listen_to_wav() {
  update_display "Playing back clip - Please listen."
  if ! "$play_cmd" "$output_dir/$(get_filename)" >/dev/null 2>&1; then
    center_text "ERROR: Playback failed with exit code $?."
  fi
}

show_item(){
  center_text "$(get_phrase $index)"
}

show_legend(){
  if [ "$index" -lt $((arraylength)) ]; then
    echo -e "${YELLOW}"
    local has_audio=${recorded[index]}
    if [ "$index" -ge "0" ]; then
      justify_text 20 "[R]ecord"
    fi
    if [ "$index" -gt "0" ] ; then
      justify_text 20 "[P]revious"
    fi
    if [ "$has_audio" = "true" ]; then
      justify_text 20 "[N]ext"
      justify_text 20 "[L]isten to saved"
    fi
    justify_text 20 "[Q]uit"
    echo -e "${RESET}"
  else
    center_text "End of dataset."
    echo
    echo
    justify_text 20 "[Q]uit"
    if [ "$arraylength" -gt "1" ] ; then
      # Only show this if more than one element
      justify_text 20 "[P]revious"
    fi
    justify_text 20 "[G]o to start"
  fi
}

update_display() {
  legendinput="$1"  # Enclose variable assignment in quotes to handle spaces correctly
  clear
  echo -e "\n\n\n\n\n\n\n\n\n\n"

  show_item
  echo -e "\n\n\n\n"
  if [ -z "$legendinput" ]; then  # Check if $legendinput is empty or not set
      show_legend
  else
      justify_text 20 "$legendinput"  # Pass $legendinput as a parameter to justify_text
  fi
}

### Main script logic

trap cleanup SIGINT SIGTERM
csv_file="${1:-metadata.csv}"
output_dir="${2:-$OUTPUT_DIR}"

if ! choose_os_command; then
  echo "Program requirements not satisfied, cannot continue..."
  exit 1
fi

load_metadata
check_files
index=0
#output_recorded
clear
echo -e "\n\n\n\n\n\n\n"
center_text "Texty Mcspeechy speedy dataset recorder"
echo
center_text "Painlessly record a dataset for any 'metadata.csv' file"

if [ -n "$csv_file" ]; then
  center_text "Recording dataset for your csv file : $csv_file"
  echo
  center_text "Writing audio files to output folder : $output_dir"
else
  center_text "optional usage: ./dataset_recorder.sh [<your_metadata.csv>]  [<directory for recordings>]"
fi

echo
echo
center_text "press <ENTER>"
read -r
update_needed=true
if [ $has_recordings -gt 0 ]; then
  clear
  echo -e "\n\n\n\n\n"
  center_text "$has_recordings file(s) from a previous session out of $arraylength already exist in directory \"$output_dir\"."
  if [ $no_recording_index -ge 0 ]; then
    center_text "The first item with no recording is item #$(no_recording_index + 1)."
  else
    center_text "All items already have a previous recording."
  fi
  echo
  center_text "Would you like to:"
  justify_text 20 "  [D]elete files and start over"
  justify_text 20 "  [C]ontinue where you left off"
  justify_text 32 "  [Q]uit"
  read -r -n 1 choice
  case "$choice" in
    d|D)
      echo "Deleting files..."
      rm "$output_dir"/*.wav
      index=0
      ;;
    c|C)
      echo "Continuing..."
      if [ $no_recording_index -ge 0 ]; then
        index=$no_recording_index
      else
        index=0
      fi
      ;;
    q|Q)
      restore_terminal_output  # Ensure terminal settings are restored on exit
      exit 0
      ;;
    *)
      :  # do nothing
      ;;
  esac
else
  index=0
fi
hide_terminal_output

#update_display

while true; do
  if [ "$update_needed" = "true" ]; then
    update_display
    update_needed=false
  fi
  read -r -n 1 keypress

  case "$keypress" in
    r|R)
      # Don't allow recording when out of dataset
      if [ $index -lt $((arraylength)) ]; then
        start_recording $index
        index=$((index + 1))
        update_needed=true
      fi
      ;;
    p|P)
      if [ $index -ge 1 ]; then
        index=$((index - 1))
        update_needed=true
      fi
      ;;
    g|G)
      if [ $index -ne 0 ]; then
        index=0
        update_needed=true
      fi
      ;;
    l|L)
      listen_to_wav
      update_needed=true
      ;;
    n|N)
      has_audio=${recorded[index]}
      echo
      if [ $index -lt $arraylength ]  && [ "$has_audio" = "true" ]; then
        index=$((index + 1))
        update_needed=true
      fi
      ;;
    q|Q)
      restore_terminal_output  # Ensure terminal settings are restored on exit
      exit 0
      ;;
    *)
      :  # do nothing
      ;;
  esac
done

