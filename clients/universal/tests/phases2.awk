$3=="B" && $8=="warm" {s=$6; b[s]=$7}
$3=="Q" && ($5 in b) && $12>0 {q[$5]=$8}
$3=="q" && ($5 in b) {m2[$5]=$11; m3[$5]=$12; ts[$5]=$13; tf[$5]=$14}
END { n=0; for (s in q) if (m3[s]>0) { n++; A[n]=(m3[s]-m2[s])/1000; B[n]=(ts[s]-m3[s])/1000; C[n]=(tf[s]-ts[s])/1000; D[n]=(q[s]-tf[s])/1000 }
  printf "  n %d: \\shipout %.2f, after ship to stop signal seen (pad, \\pdffilesize lookup) %.2f, fflush(NULL) %.2f, write the lines %.2f ms\n", n, med(A,n), med(B,n), med(C,n), med(D,n) }
function med(a,n,  i,j,t){ for(i=1;i<=n;i++)for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}; return a[int((n+1)/2)] }
