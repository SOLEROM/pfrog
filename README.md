# pfrog


![alt text](image-2.png)


![alt text](image.png)

![alt text](image-1.png)

* deps
```
type bash tar md5sum awk flock mktemp date mkdir rm mv cp sed grep
```

### play

```
export PFROG_ROOT=./testFOLDER/nfsFOLDER
./pfrog.sh list
./pfrog.sh list boardA
./pfrog.sh push boardA rootfs testFOLDER/wrkFOLDER/AAA
./pfrog.sh pull 
./pfrog.sh pull boardA
./pfrog.sh pull boardA rootfs
./pfrog.sh pull boardA rootfs --tag

./pfrog.sh list --help
./pfrog.sh push --help
./pfrog.sh pull --help

```