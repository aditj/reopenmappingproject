##############################################################################
##############################################################################
######                                                                  ######
######           reopen mapping project -- grid search                  ######
######                                                                  ######
##############################################################################
##############################################################################


## a formal estimation procedure is currently under development 

### parse calibrated parameter
gridPar <- function(parm, R0scale){

  #transmission rate
  beta1<-parm[[1]]/R0scale
  beta2<-parm[[2]]/R0scale
  if(min(beta1,beta2)<0) stop("transmission rate needs to be >=0!")
  
  ### initial condition
  I0<-exp(parm[[3]])
  if(I0<=0) stop("initial infected fraction needs to be >0!")
  
  
  return(list(beta1=beta1,beta2=beta2,I0=I0))
}
  
### set up grid points
gridPoints <- function(lb, ub, step, j, g0){

  if (j==1){
    #initial round with coarse grid
    list1<-seq(lb[1],ub[1],step[1,1])
    list2<-seq(lb[2],ub[2],step[1,2])
    list3<-seq(lb[3],ub[3],step[1,3])
  }else{
    #finer grid
    list1<-seq(max(lb[1],g0[1]-step[j-1,1]),min(ub[1],g0[1]+step[j-1,1]),step[j-1,1])
    list2<-seq(max(lb[2],g0[2]-step[j-1,2]),min(ub[2],g0[2]+step[j-1,2]),step[j-1,2]) 
    list3<-seq(max(lb[3],g0[3]-step[j-1,3]),min(ub[3],g0[3]+step[j-1,3]),step[j-1,3])
  }
  return(expand.grid(list1,list2,list3))
}


### set up contact matrix and beta for each phase in the calibration
setCmatBeta <- function(policy, t, CmatList, betaList){
  
  ### which transmission parameter beta to use
  mask<-parsePolicyTag(policy,"M")
  betaVer <- ifelse(mask==4, 1, 2)
  
  ### edit global parameters
  vpar <- vparameters0
  vpar["beta"]<-betaList[betaVer]
  return(list(Cmat=CmatList[[t]], vpar=vpar))
}


# plot fit in caliration -----------------------------------------------------
plotCali <- function(fn, xdata, xfit, DC, tVertL) {
  
  if(length(xdata)!=length(xfit))  stop("data and predicted series do not have the same length!")
  
  nt<-length(xdata)
  t<-0:(nt-1)
  
  ### plot cases or deaths
  if (DC==0){
    ylbl <- "Death Per 100 000 of Population"
  }else{
    ylbl <- "Case Per 100 000 of Population"
  }
  
  ## do we export figure
  if (fn!="") pdf(fn)
  
  ### plot fit
  xdata_finite <- xdata[is.finite(xdata)]
  xfit_finite  <- xfit[is.finite(xfit)]
  plot(t, xfit, 
       ylim=c(min(0, min(xdata_finite),min(xfit_finite)), max(max(xdata_finite), max(xfit_finite))), 
       xlab="", ylab=ylbl, 
       lwd=1.5, xaxt = "n", type="l",col="red", lty=5, cex.lab=psize)
  # x-axis show dates
  t2show<-seq(0,max(t),10)
  axis(side  = 1, at = t2show, label=format(t2show+TNAUGHT, "%m/%d"))
  
  lines(t[1:nt], xdata[1:nt], type="l", lwd=1.5, col="red")
  
  ### indicate key dates
  nline<-length(tVertL)
  lcolors<-c(rep("gray",nline-2),rep("black",2))
  abline(v=tVertL,col=lcolors)
  
  if (fn!="") dev.off()
}


##########################################################################
######## main function for grid search 
##########################################################################
gridSearch <- function(m, covid){
  
  print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
  print(paste("!! Starting grid search for MSA", m))
  print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

  ### grid search input parmaeter
  gsPar <- checkLoad(gsParm)
  gsPar <- as.vector(gsPar[gsPar$msa==m,])
  if (dim(gsPar)[1]==0) stop(paste("missing MSA ", m, " in grid search parameter file", sep=""))
  gsCol <- names(gsPar)

  ### msa policy and date
  msaPD <- loadPolicyDates(m)
  
  ### initial time
  T1<-msaPD$TVec[1]
  
  ### data
  covid<-covid[covid$t>T1,]
  nt<-dim(covid)[1] 
  if(nt<gsPar$T_range_end) stop("not enough data for calibration sample period")
  
  ### contact matrices
  CmatList<-list()
  eigvList<-c()
  np<-length(msaPD$refPolicy)
  for (i in 1:np){
    if (msaPD$TVec[i]<nt){
      CmatList[[i]]<-loadData(m, msaPD$refPolicy[i])
      eigvList[i]  <-largestEigenvalue(CmatList[[i]])
      print(paste("policy in phase", i, ":",  msaPD$refPolicy[i]))
    }
  }
  np<-length(CmatList)
  print(paste(" largest eigenvalue of contact matrices=", paste(format(eigvList,digits=4), collapse=", ")))  

  ### timing
  TTTcali <-msaPD$TVec-T1
  TTTcali[np+1]<-nt-1

  ### time range of the sample used for estimation
  tRange<-seq(gsPar$T_range_start, gsPar$T_range_end)-T1
  
  #show several lines in calibration plot
  tVertL<-c(TTTcali[2:np],min(tRange)+T1,max(tRange)+T1)
  
  ### death and cases in the data
  dead<-covid$deathper100k;  try(if(any(dead<0)) stop("Error in death data."))
  case<-covid$caseper100k;   try(if(any(case<0)) stop("Error in case data."))
  
  ### lower/upper bound for beta1, beta2 and initial condition
  lb   <-unlist(gsPar[grep("lb",   gsCol, perl=T)]);  try(if(any(lb[1:2]<0)) stop("Beta1 and Beta2 must be >=0."))
  ub   <-unlist(gsPar[grep("ub",   gsCol, perl=T)])
  step1<-unlist(gsPar[grep("step", gsCol, perl=T)])
  
  ### j rounds of grid search with incrementally small steps
  step<-rbind(step1, step1*0.1, step1*0.01, step1*0.001)
  
  g0<-NA
  for (j in 1:4){
    ### grid
    gList<-gridPoints(lb, ub, step, j, g0)
    
    ### mholder for simulated death/case
    ng<-dim(gList)[1]
    fitDeath<-matrix(0,ng,nt)
    fitCase <-matrix(0,ng,nt)
    
    start_time <- Sys.time()
    for (i in 1:ng){
      ### parameters
      parm    <-gridPar(gList[i,], infectDuration*eigvList[1])
      betaList<-c(parm$beta1, parm$beta2)
      
      ### initial condition
      initNumIperType<<-parm$I0
      
      ### for different phases
      sim0<-NA
      for (t in 1:np){
        inits<-initialCondition(TTTcali[t],sim0)
        vt <- seq(0,diff(TTTcali)[t],1) 
        
        # set contact matrix and parameter in each period
        CB <- setCmatBeta(msaPD$refPolicy[[t]], t, CmatList, betaList)
        Cmat<<-CB$Cmat

        # RUN SIR
        sim_j = as.data.frame(lsoda(inits, vt, SEIIRRD_model, CB$vpar))
        
        if (t>1){
          sim0<-rbind(sim0[1:TTTcali[t],], sim_j)
        }else{
          sim0<-sim_j
        }      
      }
      
      ### simulated death and cases (per 100k) 
      fitDeath[i,]<-extractState("D",sim0)*1e3
      fitCase[i,] <-extractSeveralState(c("Ihc","Rq","Rqd","D"),sim0)*1e3
      if ((i %% 10)==0){
        print(paste(i,"/",ng,
                    " beta1=",format(parm$beta1,digits=4),
                    " beta2=",format(parm$beta2,digits=4),
                    " I0=",   format(parm$I0   ,digits=4), sep=""))
      }
    }
    
    end_time <- Sys.time()
    print(end_time - start_time)
    
    ## fit death, min squared loss
    err<-fitDeath - matrix(1,ng,1)%*%dead
    sse<-rowSums(err[,tRange]^2) 
    
    #best fit
    gstar<-which.min(sse)
    g0<-as.double(gList[gstar,])
    parm<-gridPar(g0, infectDuration*eigvList[1])
    deadfit <- fitDeath[gstar,]
    casefit <- fitCase[gstar,1:nt]*mean(case)/mean(fitCase[gstar,])
    
    ### plot comparison
    par(mfrow=c(1,2))
    plotCali("", dead, deadfit, 0, tVertL)
    plotCali("", case, casefit, 1, tVertL)
    
    ## check within grid search boundary
    if(min((g0<ub) * (g0>lb))!=1) {
      print(rbind(lb,g0,ub))
      stop(paste("grid search hit boundary, revise range of grid search in", gsParm))
    }
  }
  
  print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
  print("grid search both rounds done!!")
  print(paste(" beta1=", format(parm$beta1,digits=4),
              " beta2=", format(parm$beta2,digits=4),
              " I0=",    format(parm$I0,digits=4),sep=""))
  print("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

  
  ### export calibration results as csv
  parmOut<-matrix(c(parm$beta1,parm$beta2,parm$I0),1,3)
  colnames(parmOut)<-c("beta1","beta2","I0")
  checkWrite(file.path(calibratedParPath, paste(caliParm, m, ".csv", sep="")),
             parmOut, "calibrated parameters")
  
  
  ### plot calibration result
  fn <- file.path(outPath, "figure", paste("calibrate_beta_I0_death_msa", m, ".pdf", sep=""))
  plotCali(fn, dead, deadfit, 0, tVertL)
  print(paste("  saved plot:",fn))

  fn <- file.path(outPath, "figure", paste("calibrate_beta_I0_case_msa", m, ".pdf", sep=""))
  plotCali("", case, casefit, 1, tVertL)
  print(paste("  saved plot:",fn))
  
  par(mfrow=c(1,2))
  plotCali("", dead, deadfit, 0, tVertL)
  plotCali("", case, casefit, 1, tVertL)
  
}


### load covid death and cases data
COVID <-checkLoad(deathData)

#### foreach MSA run grid search to calibrate parameters
for (m in msaList){
  
  ### death data for this MSA
  covid<-COVID[COVID$msa==m,c("t","deathper100k","caseper100k")]
  
  ### estimate parameter
  gridSearch(m, covid)
}

rm(COVID, covid, Cmat, gridSearch)
