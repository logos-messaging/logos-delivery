const fs = require('fs-extra');
const {spawn} = require('child_process');

// Parse command line arguments
const args = process.argv.slice(2);
const forceFlagIndex = args.indexOf('--force');

const nwakuRootFolder = '../../';
// Stable messaging header + the advanced kernel header it includes. Both must
// be copied so the kernel header's `#include "liblogosdelivery.h"` resolves.
const headers = [
  {src: 'library/liblogosdelivery.h', dst: 'android/app/src/main/jni/liblogosdelivery.h'},
  {src: 'library/liblogosdelivery_kernel.h', dst: 'android/app/src/main/jni/liblogosdelivery_kernel.h'},
];

// Android --------------------------------------------------------------------------------------

const androidArchitectures = ['arm64-v8a', 'x86', 'x86_64']; // 'armeabi-v7a'
const androidSrcFolder = 'build/android';
const androidDstFolder = 'android/app/src/main/jniLibs';
const androidFilesToCheck = ['liblogosdelivery.so', 'librln.so'];

const androidDstFiles = headers.map(h => h.dst);
androidArchitectures.forEach(architecture => {
  androidFilesToCheck.forEach(file => {
    androidDstFiles.push(`${androidDstFolder}/${architecture}/${file}`);
  });
});

// Check if all files exist
const filesExist = androidDstFiles.every(file => fs.existsSync(file));
if (!filesExist || forceFlagIndex !== -1) {
  console.log('Running make to generate all architecture libraries...');
  const makeCommand = 'make';
  const makeProcess = spawn(makeCommand, ['liblogosdelivery-android'], {cwd: '../../'});

  makeProcess.stdout.on('data', data => process.stdout.write(data));
  makeProcess.stderr.on('data', data => process.stdout.write(data));
  makeProcess.on('close', code => {
    if (code == 0) {
      console.log('Copying generated libraries...');
      androidArchitectures.forEach(architecture => {
        androidFilesToCheck.forEach(file => {
          androidDstFiles.push(`${androidDstFolder}/${architecture}/${file}`);
          fs.copyFile(
            `${nwakuRootFolder}/${androidSrcFolder}/${architecture}/${file}`,
            `${androidDstFolder}/${architecture}/${file}`,
            err => {
              if (err) throw err;
            },
          );
        });
      });
      console.log('Copying headers...');
      headers.forEach(header => {
        fs.copyFile(
          `${nwakuRootFolder}/${header.src}`,
          header.dst,
          err => {
            if (err) throw err;
          },
        );
      });
    } else {
      console.error(`make exited with ${code}`);
    }
  });
} else {
  console.log('All files exist. Skipping make.');
}
