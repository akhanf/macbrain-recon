#!/usr/bin/env node

const axios = require('axios')
const xml2js = require('xml2js')
const sharp = require('sharp')
const fs = require('fs')
const path = require('path')
const cheerio = require('cheerio')

const { program } = require('commander')

// Set the version of your CLI (optional)
program.version('0.1.0')

// Define your command-line options
program
  .requiredOption('-b, --base-url <url>', 'Base URL')
  .requiredOption('-s, --subject <subject>', 'Subject')
  .requiredOption('-t, --stain <stain>', 'Stain')
  .requiredOption('-d, --dspow <number>', 'Downsample Power of 2', parseInt)
  .requiredOption('-o, --out-dir <path>', 'Output directory')

// Parse the command-line arguments
program.parse(process.argv)

// Access the values of the options
const { baseUrl, subject, stain, dspow, outDir } = program.opts()

console.log('Base URL:', baseUrl)
console.log('Subject:', subject)
console.log('Stain:', stain)
console.log('Downsample Power (e.g. 6 to downsample by 2^6):', dspow)
console.log('Output directory:', outDir)

const downsample = 2 ** dspow

let tileSources

getTileSources(baseUrl)
  .then((fetchedTileSources) => {
    tileSources = fetchedTileSources
    console.log(tileSources)

    fs.mkdir(outDir, { recursive: true }, (err) => {
      if (err) throw err
    })

    tileSources.forEach((dziURL, slice) => {
      console.log(`Slice: ${slice}, URL: ${dziURL}`)
      const formattedSlice = String(slice).padStart(3, '0') // "005"
      downloadImage(dziURL, dspow, `${outDir}/sub-${subject}_stain-${stain}_downsample-${downsample}_slice-${formattedSlice}.jpg`)
    })
  })
  .catch(error => console.error(error))

async function getTileSources (baseUrl) {
  try {
    const response = await axios.get(baseUrl)
    const html = response.data
    const regex = /tileSources:\s*"([^"]+\/[0-9]+\.dzi)"/
    const $ = cheerio.load(html)

    tileSources = []

    $('script[type="text/javascript"]').each((index, element) => {
      const scriptContent = $(element).html()

      console.log(scriptContent)

      const match = scriptContent.match(regex)

      if (match) {
        console.log(match)
        console.log('Match found:', match[0])
        console.log('Value:', match[1])
        tileSources.push(path.join(baseUrl, match[1]))
      }
    })

    console.log(tileSources.length)
    return tileSources
  } catch (error) {
    console.error('Error fetching the URL:', error.message)
  }
}

async function findMaxZoomLevel (dziUrl, format) {
  for (let level = 20; level >= 0; level--) { // start from a reasonably high number
    const tileUrl = dziUrl.replace('.dzi', `_files/${level}/0_0.${format}`)
    try {
      const response = await axios.head(tileUrl)
      if (response.status === 200) {
        return level
      }
    } catch (error) {
      // ignore error and try next level
    }
  }
  throw new Error('No zoom levels found')
}

function getImageSizeAtLevel (width, height, maxLevel, level) {
  const scale = Math.pow(2, maxLevel - level)
  return {
    width: Math.ceil(width / scale),
    height: Math.ceil(height / scale)
  }
}

function getNumberOfTilesAtLevel (width, height, tileSize) {
  return {
    tilesX: Math.ceil(width / tileSize),
    tilesY: Math.ceil(height / tileSize)
  }
}

async function downloadImage (dziUrl, dspow, outJPEG) {
  // Download the .dzi file
  const response = await axios.get(dziUrl)
  const xml = response.data

  // Parse the .dzi file
  const parser = new xml2js.Parser()
  const result = await parser.parseStringPromise(xml)
  const image = result.Image
  const fullsize = image.Size[0].$
  const format = image.$.Format
  const tileSize = parseInt(image.$.TileSize)

  const maxLevel = await findMaxZoomLevel(dziUrl, 'jpeg')

  const level = maxLevel - dspow
  const fullSize = { width: parseInt(fullsize.Width), height: parseInt(fullsize.Height) }

  const sizeAtLevel = getImageSizeAtLevel(fullSize.width, fullSize.height, maxLevel, level)
  console.log('Size at level', level, ':', sizeAtLevel)

  const numTiles = getNumberOfTilesAtLevel(sizeAtLevel.width, sizeAtLevel.height, tileSize)

  console.log('Max zoom level:', maxLevel)

  // Create a blank canvas to draw the tiles onto
  let canvas = sharp({
    create: {
      width: sizeAtLevel.width,
      height: sizeAtLevel.height,
      channels: 3,
      background: { r: 0, g: 0, b: 0 }
    }
  })

  const overlays = []

  // Download and draw each tile
  for (let y = 0; y < numTiles.tilesY; y++) {
    for (let x = 0; x < numTiles.tilesX; x++) {
      console.log(dziUrl.replace('.dzi', `_files/${level}/${x}_${y}.${format}`))
      const tileUrl = dziUrl.replace('.dzi', `_files/${level}/${x}_${y}.${format}`)
      const response = await axios.get(tileUrl, { responseType: 'arraybuffer' })
      const tile = sharp(response.data)
      const tileBuffer = await tile.toBuffer()
      overlays.push({ input: tileBuffer, left: x * tileSize, top: y * tileSize })
    }
  }

  canvas = await canvas.composite(overlays)

  // Save the final image
  await canvas.toFile(outJPEG)
}
