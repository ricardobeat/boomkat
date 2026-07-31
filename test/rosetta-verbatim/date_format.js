// Verbatim from https://rosettacode.org/wiki/Date_format (JavaScript block 0)
// Fetched by scripts/fetch_rosetta.py -- do not edit; edit the .check.js instead.
const date = new Date('2007-11-23T00:00:00Z')

const concise = date.toISOString().split('T', 1)[0]

const pretty = date.toLocaleString('en-US', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
})

console.log({ concise, pretty })
