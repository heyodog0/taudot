# TAU_PHASES: per typing key, pass ready -> flush line read -> \par start -> \par done -> lines taken -> lines written
$3=="B" && $8=="warm" {s=$6; b[s]=$7}
$3=="Q" && ($5 in b) && $12>0 {q[$5]=$8; st[$5]=$10; fl[$5]=$11}
$3=="q" && ($5 in b) {m0[$5]=$9; m1[$5]=$10; m2[$5]=$11}
END { n=0; for (s in q) if (m0[s]>0 && m2[s]>0) { n++; A[n]=(fl[s]-b[s])/1000; B[n]=(m0[s]-fl[s])/1000; C[n]=(m1[s]-m0[s])/1000; D[n]=(m2[s]-m1[s])/1000; E[n]=(q[s]-m2[s])/1000; T[n]=(q[s]-b[s])/1000 }
  printf "  n %d: read paragraph %.2f, flush tokens %.2f, \\par (line breaking) %.2f, page builder + \\output + take lines %.2f, ship + write %.2f; total %.2f ms (p50 each)\n", n, med(A,n), med(B,n), med(C,n), med(D,n), med(E,n), med(T,n) }
function med(a,n,  i,j,t){ for(i=1;i<=n;i++)for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}; return a[int((n+1)/2)] }
