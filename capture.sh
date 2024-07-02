#!/bin/bash
#
# The script accepts the audio device ID as paramater, the user will be asked.
# To get a listing of device IDs:
# ffmpeg -f avfoundation -list_devices true -i ""
#

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
FOLDER="$HOME/capture"
if [ ! -d "$FOLDER" ]; then
  mkdir "$FOLDER"
fi

# Make sure DEVICE_INDEX is set to the user preferences.
output=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1)
output=$(sed -n '/AVFoundation audio devices:/,$p' <<< "$output")
output=$(grep '^\[AVFoundation indev @' <<< "$output")
output=$(sed -E 's/\[AVFoundation indev @ [x0-9a-f]+] //' <<< "$output")
output=$(tail -n +2 <<< "$output")

DEVICE_INDEX=$1

if [ -z "$DEVICE_INDEX" ]; then
    echo "Please choose your capturing device:"
    echo "$output" 
    read -p "Type the number:" -n 1 -r key
    DEVICE_INDEX=$key
fi
echo
echo "using device:"
echo "$output" | grep "\[$DEVICE_INDEX\]"
# No error check on DEVICE_INDEX

# Start recording audio from the aggregate device
ffmpeg -y -f avfoundation -i ":$DEVICE_INDEX" -ar 16000 -ac 1 "$FOLDER/capture_$TIMESTAMP.wav" &
FFMPEG_PID=$!

# Wait for a keypress
read -n 1 -s -r -p "Press any key to stop recording"
echo "---"
echo "KEY PRESSED, STOPPING CAPTURING"
echo "---"

# Stop recording
kill $FFMPEG_PID
wait $FFMPEG_PID
echo "done, starting transcription"

# Convert audio to text using whisper
touch "$FOLDER/capture_$TIMESTAMP.txt"
~/Development/whisper.cpp/main -m ~/Development/whisper.cpp/models/ggml-large-v2.bin -f "$FOLDER/capture_$TIMESTAMP.wav"  -otxt -of "$FOLDER/capture_$TIMESTAMP"

# The prompt
prompt="Format your answer in HTML. Summarize the given transcript. Start with the date and time if given in the transcript, otherwise use $TIMESTAMP. of the following only apply what is covered in the transcript: Identify the participants and their roles. Identify main topics discussed and summarize key points for each. If decisions were made, state them clearly. If there are follow-up actions or activities, include them in a separate paragraph. Mention the time allotted for each topic or task. Only include these sections if applicable. Transcript: "
transcript=$prompt$(cat "$FOLDER/capture_$TIMESTAMP.txt")
echo $prompt


# Calculating required context window. 
# By rule of thumb a token is 0,75 words in prose, but just about 50% of that in a conversation. 
# In result we need to go with 2,5 tokens per word in order to cover the input.
words=$(wc -w <<< "$transcript")
context=$(echo "$words * 2.5" | bc | awk '{printf "%.0f\n", (int($1 / 1000) + 1) * 1000}')

# Summarize the transcript using ollama
echo "---"
echo "Creating summary - this may take several minutes"
echo "Input is $words words, using a context window of $context tokens"

json=$(jq -n --arg transcript "$transcript" --arg context "$context" '{"model": "llama3-gradient", "num_ctx": $context, "temperature": 0.1, "top-k":10, "top-p": 0.5, "stream": false, "prompt": $transcript}')
summary=$(curl http://localhost:11434/api/generate -s -d "$json" | jq -r '.response')

# Send the email using Outlook
echo "Creating mail"
osascript -e "
tell application \"Microsoft Outlook\"
    set newMessage to make new outgoing message with properties {subject:\"Meeting Summary\", content:\"${summary//\"/\\\"}\"}
    open newMessage
    activate
end tell"

echo "Done!"
