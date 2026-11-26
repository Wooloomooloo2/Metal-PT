-- "Capped at N" (spec §4.E frame caps): the median cap when ≥ 75 % of a group's eligible runs are frame-capped;
-- NULL otherwise. Written by the API's group recompute with the other cached statistics.
ALTER TABLE "groups" ADD COLUMN capped_at INTEGER;
