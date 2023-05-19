#!/bin/bash

if [ "$#" -lt 2 ]
then
    echo "Usage: $0 <input folder> <output folder>"
    exit 1
fi
input_folder=$1
output_folder=$2

# Get the largest dimensions
max_width=0
max_height=0

for image in $input_folder/*.jpg; do
    dimensions=$(identify -format "%wx%h" "${image}")
    width=$(echo "${dimensions}" | cut -d "x" -f 1)
    height=$(echo "${dimensions}" | cut -d "x" -f 2)

    if [[ "${width}" -gt "${max_width}" ]]; then
        max_width="${width}"
    fi

    if [[ "${height}" -gt "${max_height}" ]]; then
        max_height="${height}"
    fi
done

echo "Largest dimensions found: ${max_width}x${max_height}"

# Create a new folder for the resized images
mkdir -p "${output_folder}"


# Pad images and place them in the center
for image in $input_folder/*.jpg; do
    image_name=${image##*/}
    output_image="${output_folder}/${image_name}"
    convert "${image}" -gravity center -background white -extent "${max_width}x${max_height}" "${output_image}"
    echo "Padded ${image} -> ${output_image}"
done


echo "All images have been padded and saved in the '${output_folder}' folder."

