#!/usr/bin/env Rscript
#' lpme_OneRun
#'
#' Implements analysis for latent variable models with measurement error correction
#'
#' @param Yobs A vector of observed outcome variables
#' @param ObservablesMat A matrix of observable indicators used to estimate the latent variable
#' @param ObservablesGroupings A vector specifying groupings for the observable indicators. Default is column names of ObservablesMat.
#' @param MakeObservablesGroupings Logical. If TRUE, creates dummy variables for each level of the observable indicators. Default is FALSE.
#' @param seed Random seed for reproducibility. Default is a random integer between 1 and 10000.
#'
#' @return A list containing various estimates and statistics:
#' \itemize{
#'   \item OLSCoef: Coefficient from naive OLS regression
#'   \item OLSSE: Standard error of naive OLS coefficient
#'   \item OLSTstat: T-statistic of naive OLS coefficient
#'   \item Corrected_OLSCoef: OLS coefficient corrected for measurement error
#'   \item Corrected_OLSSE: Standard error of corrected OLS coefficient (currently NA)
#'   \item Corrected_OLSTstat: T-statistic of corrected OLS coefficient (currently NA)
#'   \item Corrected_OLSCoef_alt: Alternative corrected OLS coefficient
#'   \item IVRegCoef: Coefficient from instrumental variable regression
#'   \item IVRegSE: Standard error of IV regression coefficient
#'   \item IVRegTstat: T-statistic of IV regression coefficient
#'   \item x.est1: First set of latent variable estimates
#'   \item x.est2: Second set of latent variable estimates
#'   \item Corrected_IVRegCoef: IV regression coefficient corrected for measurement error
#'   \item Corrected_IVRegSE: Standard error of corrected IV coefficient (currently NA)
#'   \item Corrected_IVRegTstat: T-statistic of corrected IV coefficient
#'   \item VarEst_split: Estimated variance of the measurement error
#' }
#'
#' @details 
#' This function implements a latent variable analysis with measurement error correction. 
#' It splits the observable indicators into two sets, estimates latent variables using each set, 
#' and then applies various correction methods including OLS correction and instrumental variable approaches.
#'
#' @examples
#' # Generate some example data
#' set.seed(123)
#' Yobs <- rnorm(100)
#' ObservablesMat <- as.data.frame( matrix(sample(c(0,1), 1000*10, replace = T), ncol = 10) )
#' 
#' # Run the analysis
#' results <- lpme_OneRun(Yobs, ObservablesMat)
#' 
#' # View the corrected OLS coefficient
#' print(results$Corrected_OLSCoef)
#'
#' @export
#' @importFrom stats lm cor var rnorm
#' @importFrom AER ivreg
#' @importFrom MCMCpack rollcall

lpme_OneRun <- function(Yobs,
                         ObservablesMat, 
                         ObservablesGroupings = colnames(ObservablesMat),
                         MakeObservablesGroupings = F, 
                         seed = runif(1, 1, 10000)){
  library(emIRT);
  items.split1_names <- sample(unique(ObservablesGroupings), 
                               size = floor(length(unique(ObservablesGroupings))/2), replace=F)
  items.split2_names <- unique(ObservablesGroupings)[! (ObservablesGroupings %in% items.split1_names)]
  for(split_ in c("", "1", "2")){
    if(split_ == ""){ items.split_ <- 1:length(ObservablesGroupings) }
    if(split_ == "1"){ items.split_ <- (1:length(ObservablesGroupings))[ObservablesGroupings %in% items.split1_names] }
    if(split_ == "2"){ items.split_ <- (1:length(ObservablesGroupings))[ObservablesGroupings %in% items.split2_names] }
    
    # estimating ideal points
    if(MakeObservablesGroupings == F){
      ObservablesMat_ <- ObservablesMat[,items.split_]
    }
    if(MakeObservablesGroupings == T){
      ObservablesMat_ <- do.call(cbind,unlist(apply(ObservablesMat[,items.split_],2,function(zer){
        list( model.matrix(~0+as.factor(zer))[,-1] )}),recursive = F))
    }
    x_init <- apply( ObservablesMat_, 1, function(x){ mean(f2n(x), na.rm=T)})
    rc_ <- convertRC( RC.SIM_ <- rollcall(ObservablesMat_) )
    p_ <- makePriors(rc_$n, rc_$m, 1)
    s_ <- list("alpha" = matrix(rnorm(ncol(ObservablesMat_))),
               "beta" = matrix(rnorm(ncol(ObservablesMat_))),
               "x" = matrix(x_init))
    
    # fixing in case directions of s1 and s2 x starts are flipped
    if(split_ %in% c("1","2")){ if(cor(s_$x, s_past$x) < 0){ s_$x <- -s_$x; s_$beta <- -s_$beta } }
    lout.sim_ <- binIRT(.rc = rc_, .starts = s_, .priors = p_, .control={
                          list(threads=1, verbose=FALSE, thresh=1e-6) },
                        .anchor_subject = which.max(x_init)) # set direction
    x.est_ <- scale(lout.sim_$means$x); s_past <- s_
    if(cor(x.est_, Yobs, use="p") < 0){ x.est_ <- -x.est_ }
    eval(parse(text = sprintf("x.est%s <- x.est_", split_)))
  }

  # simple linear reg 
  theOLS <- lm(Yobs ~ x.est)
  
  # stage 1 results
  IVStage1 <- lm(x.est2 ~ x.est1)
  
  # save baseline IV results
  IVStage2_a <- AER::ivreg(Yobs ~ x.est2 | x.est1)
  IVStage2_b <- AER::ivreg(Yobs ~ x.est1 | x.est2)
  Corrected_IVRegCoef_a <- (coef(IVStage2_a)[2] * sqrt( max(c(0.01,cor(x.est1, x.est2) ))))
  Corrected_IVRegCoef_b <- (coef(IVStage2_b)[2] * sqrt( max(c(0.01,cor(x.est1, x.est2) ))))
  Corrected_IVRegCoef <- ( Corrected_IVRegCoef_a + Corrected_IVRegCoef_b )/2
  
  # method 2 
  # assume x.est1 and x.est2 have same measurement error variance 
  # then var(x.est1 - x.est2) = var(x.est1) + var(x.est2) =  var(u.1) + var(u.2)
  # then var(x.true + u.1 - (x.true + u.2)) = var(u.1-u.2) = var(u.1) + var(u.2) = 2*var(u.1) = 2*var(u.2)
  # assume same measurement error variance
  # covariance - vary to do sensitivity 
  # x.est1 = x.true + u.1, u.1 -> measurement error for partition 1
  # x.est2 = x.true + u.2, u.2 -> measurement error for partition 1
  # assume indepedence and then var(u.1) = var(u.2)
  # var(u.1) = 2 * var( x.est1 - x.est2 ) 
  if(T == T){ 
  sigma2_corrected2 <- sigma2_corrected1 <- 2 * var( (x.est1 - x.est2) )  
  Corrected_OLSCoef1 <- coef(lm(Yobs ~ x.est1))[2] * (sqrt(1 + sigma2_corrected1))
  Corrected_OLSCoef2 <- coef(lm(Yobs ~ x.est2))[2] * (sqrt(1 + sigma2_corrected2))
  Corrected_OLSCoef_alt <- (Corrected_OLSCoef1 + Corrected_OLSCoef2)/2
  }
  
  # method 3
  if(T == T){ 
    Corrected_OLSCoef1 <- coef(lm(Yobs ~ x.est1))[2] * (CorrectionFactor <- 1/sqrt( max(c(0.01,cor(x.est1, x.est2) ))))
    Corrected_OLSCoef2 <- coef(lm(Yobs ~ x.est2))[2] * CorrectionFactor
    Corrected_OLSCoef <- (Corrected_OLSCoef1 + Corrected_OLSCoef2)/2
  }
  
  # save results 
  return(
  list("OLSCoef" = coef(summary(theOLS))[2,1],
       "OLSSE" = coef(summary(theOLS))[2,2],
       "OLSTstat" = coef(summary(theOLS))[2,3],
       
       "Corrected_OLSCoef" = Corrected_OLSCoef, 
       "Corrected_OLSSE" = NA,
       "Corrected_OLSTstat" = NA,
       
       "Corrected_OLSCoef_alt" = Corrected_OLSCoef_alt, 
       "Corrected_OLSSE" = NA,
       "Corrected_OLSTstat" = NA,
       
       "IVRegCoef" = coef(summary(IVStage2_a))[2,1], 
       "IVRegSE" = coef(summary(IVStage2_a))[2,2],
       "IVRegTstat" = coef(summary(IVStage2_a))[2,3],
       
       "x.est1" = x.est1,
       "x.est2" = x.est2,
       
       "Corrected_IVRegCoef" = Corrected_IVRegCoef,
       "Corrected_IVRegSE" = NA,
       "Corrected_IVRegTstat" =  Corrected_IVRegCoef / coef(summary(IVStage2_a))[2,2],
       "VarEst_split" = var(x.est1 - x.est2) / 2 )
  )
}
