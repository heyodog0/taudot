# per typing key (warm passes): signal->wake, wake->B, B->Q (ms), faults wake->B, wake->Q; QoS; pages pre-touched
$2=="signalled" {g=$1}
$3=="B" && $8=="warm" {s=$6; w[s]=$9; b[s]=$7; sig[s]=g; qos[s]=$11; fb[s]=$14-$13; tch[s]=$16}
$3=="Q" && ($5 in w) && $12>0 {q[$5]=$8}
$3=="q" {fq[$5]=$7}
END {
  n=0
  for (s in q) { n++; sw[n]=(w[s]-sig[s])/1000; wb[n]=(b[s]-w[s])/1000; bq[n]=(q[s]-b[s])/1000; f1[n]=fb[s]; f2[n]=fq[s]; Q=qos[s]; T=tch[s] }
  printf "  n %d, QoS class %s, pages pre-touched %s\n", n, Q, T
  printf "  signal->wake p50 %.2f ms, wake->pass ready p50 %.2f, pass ready->lines p50 %.2f; faults wake->ready p50 %d, wake->lines p50 %d\n", med(sw,n), med(wb,n), med(bq,n), med(f1,n), med(f2,n)
}
function med(a,n,  i,j,t){ for(i=1;i<=n;i++)for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}; return a[int((n+1)/2)] }
