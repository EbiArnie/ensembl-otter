#!/bin/sh

key="pipeline_db_head"
species_list=" 
  cat
  chicken
  chimp
  dog
  human
  mouse
  pig
  platypus
  rat
  wallaby
  zebrafish
  "

for species in $species_list
do
    ./save_satellite_db \
-dataset $species \
-key $key \
-sathost otterpipe1 \
-satuser ottro \
-satport 3302 \
-satdbname pipe_$species
done
