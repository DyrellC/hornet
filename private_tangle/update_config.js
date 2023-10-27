const { argv } = require('node:process');
const fs= require('fs');
const config_path = './config_private_tangle.json';
let config = require(config_path);
const autopeering_config_path = './config_private_tangle_autopeering.json';
let autopeering_config = require(autopeering_config_path);

class PublicKeyRange {
    constructor(key) {
        this.key = key;
        this.start = 0;
        this.end = 0;
    }
}

console.log("Updating configuration file")
let keys = Array(2, PublicKeyRange)
argv.forEach((val, index) => {
    if(index === 2) {
        keys[0] = new PublicKeyRange(val)
    }
    if(index === 3) {
        keys[1] = new PublicKeyRange(val)
    }
});

config.protocol.publicKeyRanges = keys
autopeering_config.protocol.publicKeyRanges = keys
fs.writeFile(config_path, JSON.stringify(config, null, 2), (err) => {
    if(err != null) {
        console.error('Error with writing to config file: ', err)
    }
})
fs.writeFile(autopeering_config_path, JSON.stringify(autopeering_config, null, 2), (err) => {
    if(err != null) {
        console.error('Error with writing to autopeering config file: ', err)
    }
})
console.log("Updated configuration file")