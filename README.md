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
./pfrog.sh pull boardA rootfs root=/tmp/c

./pfrog.sh pull boardA rootfs 2 
./pfrog.sh pull boardA rootfs 2 root=/tmp/d

./pfrog.sh pull boardA rootfs 1f93cf3ce72efd9a970f2e39944afcde          
./pfrog.sh pull boardA rootfs 1f93cf3ce72efd9a970f2e39944afcde  root=/tmp/d

./pfrog.sh compare boardA rootfs root=/tmp/c
./pfrog.sh compare boardA rootfs root=/tmp/c --tag

./pfrog.sh list --help
./pfrog.sh push --help
./pfrog.sh pull --help

```