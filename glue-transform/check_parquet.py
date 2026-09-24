import sys
import pyarrow as pa
import pyarrow.parquet as pq
import pyarrow.compute as pc

f = pq.ParquetFile(sys.argv[1])
print("rows:", f.metadata.num_rows)
print(f.schema_arrow)

# Only two small columns for the full-table counts, to keep memory low
t = f.read(columns=["TYPE", "VALUE_NUM"])
is_num = pc.equal(t["TYPE"], "numeric")
print("TYPE counts:", pc.value_counts(t["TYPE"]).to_pylist())
print("numeric rows with NULL VALUE_NUM:",
      pc.sum(pc.and_(is_num, pc.is_null(t["VALUE_NUM"]))).as_py())
print("non-numeric rows WITH a VALUE_NUM:",
      pc.sum(pc.and_(pc.invert(is_num), pc.is_valid(t["VALUE_NUM"]))).as_py())

# Samples from the first 200k rows
cols = ["DATE", "TYPE", "VALUE", "VALUE_NUM", "UNITS"]
first = pa.Table.from_batches([next(f.iter_batches(batch_size=200000, columns=cols))])
print("sample numeric:", first.filter(pc.equal(first["TYPE"], "numeric")).slice(0, 3).to_pylist())
print("sample text:", first.filter(pc.not_equal(first["TYPE"], "numeric")).slice(0, 3).to_pylist())
